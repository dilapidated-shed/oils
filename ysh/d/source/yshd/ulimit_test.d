module yshd.ulimit_test;

version (unittest) {
    import core.sys.posix.sys.resource : rlimit, rlim_t, RLIM_INFINITY,
        RLIMIT_FSIZE, RLIMIT_NOFILE, RLIMIT_CPU, getrlimit;
    import core.sys.posix.unistd : fork, _exit, write;
    import core.sys.posix.signal : signal, SIG_DFL, SIGXFSZ;
    import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS, WIFSIGNALED, WTERMSIG;
    import core.stdc.errno : errno, EINTR;
    import std.stdio : File, stderr;
    import std.conv : to;
    import std.string : startsWith, splitLines;
    import yshd.state : Memory;
    import yshd.ulimit : runUlimit;
    import yshd.value : UsageError;

    private rlimit query(int resource) {
        rlimit limits;
        assert(getrlimit(resource, &limits) == 0);
        return limits;
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string result;
        while (!file.eof()) result ~= file.readln();
        return result;
    }

    private void isolated(void delegate() body) {
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            try { body(); }
            catch (Throwable error) { stderr.writeln(error); _exit(91); }
            _exit(0);
        }
        int status;
        int observed;
        do { observed = waitpid(child, &status, 0); }
        while (observed < 0 && errno == EINTR);
        assert(observed == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "isolated native ulimit control failed");
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, File.tmpfile());
        auto limits = query(RLIMIT_NOFILE);
        assert(runUlimit(["-n"], mem) == 0);
        assert(contents(output) == to!string(limits.rlim_cur) ~ "\n");
        auto all = File.tmpfile();
        mem.outputFile = all;
        assert(runUlimit(["--all=0", "-H", "-S"], mem) == 0);
        auto text = contents(all);
        assert(text.startsWith(" FLAG            SOFT            HARD  FACTOR  DESC\n"));
        assert(text.splitLines().length == 8);
        assert(query(RLIMIT_NOFILE) == limits);
    }

    unittest {
        auto parent = query(RLIMIT_FSIZE);
        isolated({
            auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
            assert(runUlimit(["-f", "3"], mem) == 0);
            auto limits = query(RLIMIT_FSIZE);
            assert(limits.rlim_cur == 1536 && limits.rlim_max == 1536,
                "ulimit -f must apply 512-byte units and set both limits");
            assert(runUlimit(["-S", "-f", "2"], mem) == 0);
            limits = query(RLIMIT_FSIZE);
            assert(limits.rlim_cur == 1024 && limits.rlim_max == 1536,
                "soft-only ulimit changed the hard limit");
            // Lowering hard below current soft is invalid for every privilege
            // level. The kernel must reject it without changing either value.
            assert(runUlimit(["-H", "-f", "1"], mem) == 1);
            assert(query(RLIMIT_FSIZE) == limits, "rejected limit change mutated kernel state");
            assert(runUlimit(["-HSf", "1"], mem) == 0);
            limits = query(RLIMIT_FSIZE);
            assert(limits.rlim_cur == 512 && limits.rlim_max == 512);
        });
        assert(query(RLIMIT_FSIZE) == parent, "resource controls changed the parent runner");
    }

    unittest {
        auto parent = query(RLIMIT_NOFILE);
        auto fileSize = query(RLIMIT_FSIZE);
        isolated({
            auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
            auto amount = parent.rlim_max == RLIM_INFINITY || parent.rlim_max > 4096 ? 4096 : parent.rlim_max;
            assert(runUlimit(["-Sn", to!string(amount)], mem) == 0);
            auto limits = query(RLIMIT_NOFILE);
            assert(limits.rlim_cur == amount && limits.rlim_max == parent.rlim_max);
            assert(runUlimit(["-H", "-n", to!string(amount)], mem) == 0);
            limits = query(RLIMIT_NOFILE);
            assert(limits.rlim_cur == amount && limits.rlim_max == amount);
            assert(query(RLIMIT_FSIZE) == fileSize, "ulimit changed a different resource");
        });
        assert(query(RLIMIT_NOFILE) == parent);
    }

    unittest {
        isolated({
            auto parent = query(RLIMIT_CPU);
            auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
            assert(runUlimit(["-S", "-t", "123456"], mem) == 0);
            auto limits = query(RLIMIT_CPU);
            assert(limits.rlim_cur == 123456 && limits.rlim_max == parent.rlim_max);
            assert(runUlimit(["-S", "-t", "unlimited"], mem) == 0);
            limits = query(RLIMIT_CPU);
            assert(limits.rlim_cur == RLIM_INFINITY && limits.rlim_max == parent.rlim_max);
        });
    }

    unittest {
        static if (rlim_t.sizeof >= 8) isolated({
            auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
            assert(runUlimit(["-f", "9007199254740992"], mem) == 0);
            auto limits = query(RLIMIT_FSIZE);
            assert(limits.rlim_cur == 4611686018427387904UL && limits.rlim_max == limits.rlim_cur);
            bool rejected;
            try { runUlimit(["-f", "18014398509481984"], mem); }
            catch (UsageError error) { rejected = true; }
            assert(rejected && query(RLIMIT_FSIZE) == limits,
                "signed scaled-limit overflow reached the kernel");
        });
    }

    unittest {
        auto before = query(RLIMIT_FSIZE);
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        foreach (words; [["-fn"], ["-af"], ["--all", "42"], ["-Q"],
                ["-f", "1", "2"], ["-f", "--", "-1"], ["-f", "0x10"], ["+1"]]) {
            bool rejected;
            try { runUlimit(words, mem); }
            catch (UsageError error) { rejected = true; }
            assert(rejected && query(RLIMIT_FSIZE) == before);
        }
    }

    unittest {
        auto before = query(RLIMIT_FSIZE);
        auto output = File.tmpfile();
        auto target = File.tmpfile();
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            signal(SIGXFSZ, SIG_DFL);
            auto mem = new Memory(File.tmpfile(), output, File.tmpfile());
            import yshd.program : executeProgram;
            executeProgram("ulimit -f 1; echo -n completed", mem);
            char[513] bytes;
            // A real kernel limit permits the first block, then kills the
            // process on the next write. A fake setter cannot satisfy this.
            if (write(target.fileno(), bytes.ptr, bytes.length) != 512) _exit(92);
            write(target.fileno(), bytes.ptr, 1);
            _exit(93);
        }
        int status, observed;
        do { observed = waitpid(child, &status, 0); }
        while (observed < 0 && errno == EINTR);
        assert(observed == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGXFSZ,
            "file-size limit did not enforce a real SIGXFSZ boundary");
        assert(contents(output) == "completed", "completed builtin output was lost on signal exit");
        target.seek(0, 2);
        assert(target.tell() == 512);
        assert(query(RLIMIT_FSIZE) == before);
    }
}
