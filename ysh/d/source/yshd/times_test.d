module yshd.times_test;

version (unittest) {
    import core.stdc.errno : errno, EINTR;
    import core.sys.posix.fcntl : open, O_WRONLY;
    import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
    import core.sys.posix.unistd : close, fork, getpid, sysconf, write, _exit, _SC_CLK_TCK;
    import std.conv : to;
    import std.file : mkdir, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.stdio : File;
    import std.string : indexOf, split, splitLines;
    import yshd.libc_process : clock_t, tms, posixTimes = times;
    import yshd.program : runTimesSource = executeProgram;
    import yshd.state : Memory;
    import yshd.value : YshError;

    private void executeProgram(string source, Memory mem) {
        try { runTimesSource(source, mem); }
        catch (YshError error) {
            assert(false, "times test source:\n" ~ source ~ "\nfailed with: " ~ error.msg);
        }
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string text, line;
        while ((line = file.readln()).length) text ~= line;
        return text;
    }

    // Parse only the public two-row transcript. All values are milliseconds;
    // no production formatter or floating-point conversion is used as oracle.
    private ulong duration(string text) {
        assert(text.length && text[$ - 1] == 's', text);
        auto minute = text.indexOf('m');
        auto point = text.indexOf('.');
        assert(minute > 0 && point > minute + 1 && text.length == point + 5, text);
        foreach (index, character; text[0 .. $ - 1]) {
            if (index == minute || index == point) continue;
            assert(character >= '0' && character <= '9', text);
        }
        auto seconds = to!ulong(text[minute + 1 .. point]);
        assert(seconds <= 60, text); // %.3f can round 59.9996 to 60.000.
        return to!ulong(text[0 .. minute]) * 60_000 + seconds * 1000 +
            to!ulong(text[point + 1 .. $ - 1]);
    }

    private ulong[4][] reports(string text) {
        assert(text.length && text[$ - 1] == '\n', "times report has no final newline");
        auto lines = text.splitLines();
        assert(lines.length % 2 == 0, text);
        ulong[4][] result;
        foreach (report; 0 .. lines.length / 2) {
            ulong[4] values;
            foreach (row; 0 .. 2) {
                auto fields = lines[report * 2 + row].split(" ");
                assert(fields.length == 2, lines[report * 2 + row]);
                values[row * 2] = duration(fields[0]);
                values[row * 2 + 1] = duration(fields[1]);
            }
            result ~= values;
        }
        return result;
    }

    private long[4] nativeTicks() {
        tms accounting;
        assert(posixTimes(&accounting) != cast(clock_t)-1);
        return [cast(long)accounting.tms_utime, cast(long)accounting.tms_stime,
            cast(long)accounting.tms_cutime, cast(long)accounting.tms_cstime];
    }

    private ulong[4] report(Memory mem) {
        auto output = File.tmpfile();
        mem.outputFile = output;
        auto before = nativeTicks();
        executeProgram("times", mem);
        auto after = nativeTicks();
        assert(mem.lastStatus == 0);
        auto parsed = reports(contents(output));
        assert(parsed.length == 1);
        auto ticksPerSecond = sysconf(_SC_CLK_TCK);
        assert(ticksPerSecond > 0);
        foreach (field; 0 .. 4) {
            auto scaled = cast(long)parsed[0][field] * ticksPerSecond;
            // The public report rounds native ticks to milliseconds. On
            // integral-millisecond clocks even that display tolerance is zero.
            auto rounding = 1000 % ticksPerSecond == 0 ? 0 : ticksPerSecond;
            assert(scaled >= before[field] * 1000 - rounding &&
                scaled <= after[field] * 1000 + rounding,
                "times differs from native cumulative counter " ~ to!string(field));
            if (ticksPerSecond <= 1000 && 1000 % ticksPerSecond == 0)
                assert(parsed[0][field] % (1000 / ticksPerSecond) == 0,
                    "times did not preserve native clock-tick precision");
        }
        return parsed[0];
    }

    private ulong cpuWorkSink = 1;

    private void burnUserTicks() {
        auto initial = nativeTicks()[0];
        auto value = cpuWorkSink;
        foreach (batch; 0 .. 100_000) {
            foreach (iteration; 0 .. 20_000) {
                value ^= value << 13;
                value ^= value >> 7;
                value ^= value << 17;
            }
            cpuWorkSink = value;
            if (nativeTicks()[0] - initial >= 4) return;
        }
        assert(false, "native user CPU workload did not consume four ticks");
    }

    private void burnSystemTicks() {
        auto descriptor = open("/dev/null", O_WRONLY);
        assert(descriptor >= 0);
        scope (exit) close(descriptor);
        auto initial = nativeTicks()[1];
        ubyte datum;
        foreach (batch; 0 .. 100_000) {
            foreach (iteration; 0 .. 256)
                assert(write(descriptor, &datum, 1) == 1);
            if (nativeTicks()[1] - initial >= 4) return;
        }
        assert(false, "native system CPU workload did not consume four ticks");
    }

    private void grew(ulong before, ulong after, string field) {
        auto ticksPerSecond = sysconf(_SC_CLK_TCK);
        assert(after >= before && (after - before) * ticksPerSecond >= 3000,
            "times lost cumulative " ~ field ~ " CPU ticks");
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram("false; times ignored -x --help --", mem);
        assert(mem.lastStatus == 0, "times retained a prior command's failure status");
        assert(reports(contents(output)).length == 1);
        assert(contents(errors) == "", "times wrote its report to stderr");
        report(mem);
    }

    unittest {
        auto errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), errors);
        auto before = report(mem);
        burnUserTicks();
        burnSystemTicks();
        auto after = report(mem);
        grew(before[0], after[0], "self user");
        grew(before[1], after[1], "self system");
        assert(after[2 .. 4] == before[2 .. 4], "self CPU was added to child counters");

        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            burnUserTicks();
            burnSystemTicks();
            _exit(0);
        }
        int status, observed;
        do { observed = waitpid(child, &status, 0); }
        while (observed < 0 && errno == EINTR);
        assert(observed == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        auto waited = report(mem);
        grew(after[2], waited[2], "waited-child user");
        grew(after[3], waited[3], "waited-child system");
        auto repeated = report(mem);
        assert(repeated[2 .. 4] == waited[2 .. 4], "times reset cumulative child totals");
        assert(repeated[0] >= waited[0] && repeated[1] >= waited[1],
            "times reset cumulative self totals");
        assert(cpuWorkSink != 0);
        assert(contents(errors) == "");
    }

    private uint directoryIndex;
    private string directory() {
        auto path = buildPath(tempDir(), "ysh-d-times-" ~ to!string(getpid()) ~ "-" ~ to!string(directoryIndex++));
        mkdir(path);
        return path;
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto redirected = buildPath(path, "times output.txt");
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram("times > '" ~ redirected ~ "'", mem);
        assert(mem.lastStatus == 0 && reports(readText(redirected)).length == 1);
        assert(contents(output) == "" && contents(errors) == "");

        executeProgram("times >&2", mem);
        assert(mem.lastStatus == 0 && reports(contents(errors)).length == 1);
        assert(contents(output) == "");

        errors = File.tmpfile();
        mem.errorFile = errors;
        executeProgram("captured=$(times); echo \"$captured\"", mem);
        assert(mem.lastStatus == 0 && reports(contents(output)).length == 1);
        assert(contents(errors) == "");
    }

    unittest {
        foreach (source; ["times >&-", "times >/dev/full"]) {
            auto output = File.tmpfile(), errors = File.tmpfile();
            auto mem = new Memory(File.tmpfile(), output, errors);
            executeProgram(source, mem);
            assert(mem.lastStatus == 1, source ~ " swallowed an output failure");
            assert(contents(output) == "" && contents(errors).length != 0);
            // A temporary failing redirection must not poison later output.
            executeProgram("echo restored", mem);
            assert(mem.lastStatus == 0 && contents(output) == "restored\n");
        }
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram("times 2>&-", mem);
        assert(mem.lastStatus == 0 && reports(contents(output)).length == 1);
        assert(contents(errors) == "");
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        mem.options.set("ysh:all", true);
        executeProgram(`
            var calls = 0
            func argument() { setglobal calls += 1; return (42) }
            times ignored --invalid (argument(); named=argument()) { error 'block ran' }
            assert [calls === 2]
            builtin times (argument())
            command times (; named=argument())
            assert [calls === 4]
            times [unbound]
            times [argument()]
            assert [calls === 4]
            times { error 'block ran' }
            times (;; ^(error 'block ran'))
        `, mem);
        assert(mem.lastStatus == 0 && reports(contents(output)).length == 7);
        assert(contents(errors) == "");

        output = File.tmpfile();
        mem.outputFile = output;
        bool failed;
        try { runTimesSource("times (unbound)", mem); }
        catch (YshError error) { failed = error.status == 1; }
        assert(failed && contents(output) == "", "times skipped eager typed-argument evaluation");
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram(`
            times() { echo wrong; }
            times
            builtin times
            command times
            name=times
            $name
        `, mem);
        assert(mem.lastStatus == 0 && reports(contents(output)).length == 4,
            "a shell function shadowed the special times builtin");
        assert(contents(errors) == "");
    }
}
