module yshd.timing_test;

version (unittest) {
    import std.stdio : File;
    import std.conv : to;
    import std.file : tempDir, mkdir, rmdirRecurse, exists, readText,
        copy, getAttributes, setAttributes;
    import std.path : buildPath;
    import std.string : indexOf, splitLines, startsWith;
    import core.sys.posix.unistd : getpid;
    import yshd.program : runTimingSource = executeProgram, parseProgram, ShellExit, Errexit;
    import yshd.state : Memory;
    import yshd.value : Value, YshError;

    private void executeProgram(string source, Memory mem) {
        try { runTimingSource(source, mem); }
        catch (YshError error) {
            assert(false, "timing test source:\n" ~ source ~ "\nfailed with: " ~ error.msg);
        }
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string result;
        while (!file.eof()) result ~= file.readln();
        return result;
    }

    private struct Measurements {
        ulong wall, user, system;
    }

    // Validate the reference transcript without interpreting it as floating
    // point or assuming a particular host speed. Values below are milliseconds.
    private Measurements[] reports(string text) {
        assert(text.length && text[$ - 1] == '\n', "timing report has no final newline");
        auto lines = text.splitLines();
        assert(lines.length % 3 == 0, text);
        Measurements[] result;
        foreach (offset; 0 .. lines.length / 3) {
            ulong[3] values;
            foreach (field, label; ["real", "user", "sys"]) {
                auto line = lines[offset * 3 + field];
                auto prefix = label ~ "\t";
                assert(line.startsWith(prefix), line);
                auto number = line[prefix.length .. $];
                auto point = number.indexOf('.');
                assert(point > 0 && number.length == point + 4, line);
                foreach (index, character; number) {
                    if (index == point) continue;
                    assert(character >= '0' && character <= '9', line);
                }
                values[field] = to!ulong(number[0 .. point]) * 1000 + to!ulong(number[point + 1 .. $]);
            }
            result ~= Measurements(values[0], values[1], values[2]);
        }
        return result;
    }

    private uint directoryIndex;
    private string directory() {
        auto path = buildPath(tempDir(), "ysh-d-timing-" ~ to!string(getpid()) ~ "-" ~ to!string(directoryIndex++));
        mkdir(path);
        return path;
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram(`
            value=before
            TIMEFORMAT=ignored
            time { value=changed; echo body; false; }
        `, mem);
        assert(mem.wordVariable("value") == "changed", "time introduced a subshell frame");
        assert(mem.lastStatus == 1, "time replaced its child's failure status");
        assert(contents(output) == "body\n");
        assert(reports(contents(errors)).length == 1);
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        // Only the last stage sleeps. Timing the first stage instead of the
        // complete pipeline cannot account for this interval.
        executeProgram("time echo ignored | /usr/bin/sleep 0.04", mem);
        assert(mem.lastStatus == 0 && contents(output) == "");
        auto measured = reports(contents(errors));
        assert(measured.length == 1 && measured[0].wall >= 20,
            "time did not wait for the complete pipeline");

        errors = File.tmpfile();
        mem.errorFile = errors;
        executeProgram("set -o pipefail; time false | true", mem);
        assert(mem.lastStatus == 1, "time lost the complete pipeline's pipefail status");
        assert(reports(contents(errors)).length == 1);
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram(`
            time false || echo recovered
            ! time false
            echo inverted=$?
            time ! false
            echo timed-negation=$?
        `, mem);
        assert(contents(output) == "recovered\ninverted=0\ntimed-negation=0\n");
        assert(reports(contents(errors)).length == 3);

        errors = File.tmpfile();
        mem.errorFile = errors;
        executeProgram("time true && echo after >&2", mem);
        auto lines = contents(errors).splitLines();
        assert(lines.length == 4 && lines[3] == "after", "time consumed the following and/or operand");
        assert(reports(lines[0] ~ "\n" ~ lines[1] ~ "\n" ~ lines[2] ~ "\n").length == 1);
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto childError = buildPath(path, "child error.txt");
        auto outerError = buildPath(path, "outer error.txt");
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram("time { echo child >&2; } 2> '" ~ childError ~ "'", mem);
        assert(readText(childError) == "child\n");
        assert(reports(contents(errors)).length == 1,
            "child redirection captured the timing report");

        errors = File.tmpfile();
        mem.errorFile = errors;
        executeProgram("{ time { echo outer >&2; }; } 2> '" ~ outerError ~ "'", mem);
        assert(contents(errors) == "");
        auto redirected = readText(outerError);
        assert(redirected.startsWith("outer\n"));
        assert(reports(redirected["outer\n".length .. $]).length == 1,
            "outer redirection did not capture the timing report");
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram("time { time echo nested; }", mem);
        assert(contents(output) == "nested\n");
        assert(reports(contents(errors)).length == 2);

        errors = File.tmpfile();
        mem.errorFile = errors;
        mem.options.set("parse_ysh_expr_sub", true);
        executeProgram("value=$(time echo captured); echo \"$value\"", mem);
        assert(mem.wordVariable("value") == "captured");
        assert(reports(contents(errors)).length == 1,
            "command substitution swallowed or duplicated the timing report");

        errors = File.tmpfile();
        mem.errorFile = errors;
        executeProgram("time case x in x) echo matched >&2;; esac", mem);
        auto caseError = contents(errors);
        assert(caseError.startsWith("matched\n"), "timing report preceded the case body on stderr");
        assert(reports(caseError["matched\n".length .. $]).length == 1);
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto marker = buildPath(path, "not executed");
        parseProgram("time { echo wrong > '" ~ marker ~ "'; }");
        assert(!exists(marker), "parse-only time executed its child");
        parseProgram("time -p true"); // -p is a command word, not a timing flag.
        foreach (source; ["time", "time;", "time\ntrue"]) {
            bool rejected;
            try { parseProgram(source); }
            catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram("time /usr/bin/cat <<A; time /usr/bin/cat <<B\none\nA\ntwo\nB\necho after", mem);
        assert(contents(output) == "one\ntwo\nafter\n", "timed here-documents reused an earlier body");
        assert(reports(contents(errors)).length == 2);

        output = File.tmpfile();
        errors = File.tmpfile();
        mem.outputFile = output;
        mem.errorFile = errors;
        executeProgram("/usr/bin/cat <<A; /usr/bin/cat <<B\none\nA\ntwo\nB\necho after", mem);
        assert(contents(output) == "one\ntwo\nafter\n", "untimed here-document body ownership changed");
        assert(contents(errors) == "");
    }

    version (Posix) unittest {
        import core.sys.posix.unistd : fork, _exit, alarm;
        import core.sys.posix.signal : signal, SIG_DFL, SIGALRM;
        import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
        import core.stdc.errno : errno, EINTR;
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            // Structural lookahead must not repeatedly revalidate every
            // nested time subtree. Bound a regression independently of CI's
            // much longer job timeout, without changing the parent alarm.
            signal(SIGALRM, SIG_DFL);
            alarm(3);
            parseProgram("time time time time time time time time time time time time true");
            _exit(0);
        }
        int status, observed;
        do { observed = waitpid(child, &status, 0); }
        while (observed < 0 && errno == EINTR);
        assert(observed == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "twelve timing prefixes exceeded the bounded parse control");
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        bool exited;
        try { executeProgram("time exit 23; echo wrong", mem); }
        catch (ShellExit control) { exited = control.status == 23; }
        assert(exited && contents(output) == "" && contents(errors) == "",
            "time intercepted exit or printed while unwinding");

        executeProgram(`
            f() { time return 7; echo wrong; }
            f
            echo returned=$?
            for item in once; do time break; echo wrong; done
            echo broke
            for item in once; do time continue; echo wrong; done
            echo continued
        `, mem);
        assert(contents(output) == "returned=7\nbroke\ncontinued\n");
        assert(contents(errors) == "", "time reported a nonlocal control transfer");

        bool failed;
        try { executeProgram("set -e; time false; echo wrong", mem); }
        catch (Errexit control) { failed = control.status == 1; }
        assert(failed && contents(errors) == "", "time masked errexit or reported on unwind");
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto external = buildPath(path, "time");
        copy("/usr/bin/printf", external);
        setAttributes(external, getAttributes("/usr/bin/printf"));
        foreach (spelling; ["time{", "time}"]) {
            auto braceCommand = buildPath(path, spelling);
            copy(external, braceCommand);
            setAttributes(braceCommand, getAttributes(external));
        }
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        mem.get("ENV").dictValue.set("PATH", Value.str(path));
        executeProgram(`
            'time' '%s\n' quoted
            time'' '%s\n' concatenated
            t\ime '%s\n' escaped
            ti\
me '%s\n' continued-word
            time{ '%s\n' left-brace
            time} '%s\n' right-brace
            name=time
            $name '%s\n' dynamic
            command time '%s\n' command
            PREFIX=bound time '%s\n' binding
        `, mem);
        assert(contents(output) == "quoted\nconcatenated\nescaped\ncontinued-word\nleft-brace\nright-brace\ndynamic\ncommand\nbinding\n");
        assert(contents(errors) == "", "ordinary command spelling was promoted to time keyword");

        auto redirected = buildPath(path, "leading redirect.txt");
        executeProgram("2> '" ~ redirected ~ "' time '%s\\n' redirect", mem);
        assert(readText(redirected) == "", "leading redirect promoted a simple command to time keyword");
        assert(contents(output) == "quoted\nconcatenated\nescaped\ncontinued-word\nleft-brace\nright-brace\ndynamic\ncommand\nbinding\nredirect\n");
        executeProgram("builtin time", mem);
        assert(mem.lastStatus == 1 && contents(errors).indexOf("real\t") < 0,
            "time was admitted as a runtime builtin");

        // ParseTime documents [-p] but never consumes it. A real executable
        // with that spelling proves it remains the child's command name.
        auto optionCommand = buildPath(path, "-p");
        copy(external, optionCommand);
        setAttributes(optionCommand, getAttributes(external));
        output = File.tmpfile();
        errors = File.tmpfile();
        mem.outputFile = output;
        mem.errorFile = errors;
        executeProgram("time -p '%s\\n' option-command", mem);
        assert(mem.lastStatus == 0 && contents(output) == "option-command\n");
        assert(reports(contents(errors)).length == 1, "time consumed an unsupported -p flag");

        errors = File.tmpfile();
        mem.errorFile = errors;
        executeProgram("time\\\n true", mem);
        assert(mem.lastStatus == 0 && reports(contents(errors)).length == 1,
            "escaped newline after time lost keyword identity");
    }

    unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram(`
            shopt -s expand_aliases
            alias time='echo wrong'
            time true
            alias measured='time'
            measured echo alias
        `, mem);
        assert(contents(output) == "alias\n", "an alias overrode the reserved time keyword");
        assert(reports(contents(errors)).length == 2,
            "alias expansion to the keyword was not reparsed");
    }

    version (Posix) unittest {
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram("time { echo background; } & wait", mem);
        assert(mem.lastStatus == 0 && contents(output) == "background\n");
        assert(reports(contents(errors)).length == 1,
            "background timing did not finish before wait returned");
    }

    version (Posix) unittest {
        import core.sys.posix.sys.resource : rusage, getrusage, RUSAGE_SELF, RUSAGE_CHILDREN;
        rusage selfBefore, selfAfter, childBefore, childAfter;
        auto output = File.tmpfile(), errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        assert(getrusage(RUSAGE_SELF, &selfBefore) == 0);
        assert(getrusage(RUSAGE_CHILDREN, &childBefore) == 0);
        // The work stays inside native D; no external CPU helper is needed.
        executeProgram("time forkwait { for i in (0..<30000) { true } }", mem);
        assert(getrusage(RUSAGE_SELF, &selfAfter) == 0);
        assert(getrusage(RUSAGE_CHILDREN, &childAfter) == 0);
        auto measured = reports(contents(errors));
        assert(measured.length == 1);
        long selfMicros = (selfAfter.ru_utime.tv_sec - selfBefore.ru_utime.tv_sec) * 1_000_000 +
            selfAfter.ru_utime.tv_usec - selfBefore.ru_utime.tv_usec +
            (selfAfter.ru_stime.tv_sec - selfBefore.ru_stime.tv_sec) * 1_000_000 +
            selfAfter.ru_stime.tv_usec - selfBefore.ru_stime.tv_usec;
        long childMicros = (childAfter.ru_utime.tv_sec - childBefore.ru_utime.tv_sec) * 1_000_000 +
            childAfter.ru_utime.tv_usec - childBefore.ru_utime.tv_usec +
            (childAfter.ru_stime.tv_sec - childBefore.ru_stime.tv_sec) * 1_000_000 +
            childAfter.ru_stime.tv_usec - childBefore.ru_stime.tv_usec;
        assert(childMicros >= 10_000, "native child workload did not establish a CPU contrast");
        assert(measured[0].user + measured[0].system <= selfMicros / 1000 + 5,
            "time added waited-child CPU despite the retained RUSAGE_SELF contract");
    }

    version (Posix) unittest {
        import core.sys.posix.unistd : fork, _exit;
        import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
        import core.stdc.errno : errno, EINTR;
        foreach (explicitExec; [false, true]) {
            auto output = File.tmpfile(), errors = File.tmpfile();
            auto mem = new Memory(File.tmpfile(), output, errors);
            auto child = fork();
            assert(child >= 0);
            if (child == 0) {
                mem.canReplaceProcess = true;
                executeProgram(explicitExec ? "time exec /usr/bin/true" : "time /usr/bin/true", mem);
                mem.errorFile.flush();
                _exit(71);
            }
            int status, observed;
            do { observed = waitpid(child, &status, 0); }
            while (observed < 0 && errno == EINTR);
            assert(observed == child && WIFEXITED(status));
            assert(WEXITSTATUS(status) == (explicitExec ? 0 : 71),
                "time changed explicit exec or allowed premature tail replacement");
            if (explicitExec) assert(contents(errors) == "", "time resumed after native exec");
            else assert(reports(contents(errors)).length == 1, "tail exec bypassed timing report");
        }
    }
}
