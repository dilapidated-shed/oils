module yshd.umask_test;

version (unittest) {
    import core.stdc.errno : errno, EINTR;
    import core.sys.posix.fcntl : open, O_CREAT, O_EXCL, O_WRONLY;
    import core.sys.posix.sys.stat : chmod, mkdir, stat, stat_t, nativeUmask = umask;
    import core.sys.posix.sys.types : mode_t;
    import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
    import core.sys.posix.unistd : close, fork, getpid, _exit;
    import std.conv : octal, to;
    import std.file : rmdirRecurse, tempDir, writeText = write;
    import std.path : buildPath;
    import std.stdio : File, stderr;
    import std.string : indexOf, toStringz;
    import std.typecons : tuple;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : FatalRuntimeError, Value, YshError;

    private mode_t kernelMask() {
        auto previous = nativeUmask(0);
        nativeUmask(previous);
        return previous;
    }

    // A failed child assertion must not leave a changed mask in the runner.
    private void isolated(string label, void delegate() body) {
        auto before = kernelMask();
        auto child = fork();
        assert(child >= 0, label ~ ": fork failed");
        if (child == 0) {
            try { body(); }
            catch (Throwable error) {
                stderr.writeln(label, ": ", error);
                _exit(91);
            }
            _exit(0);
        }
        int status, observed;
        do { observed = waitpid(child, &status, 0); }
        while (observed < 0 && errno == EINTR);
        assert(kernelMask() == before, label ~ ": changed parent runner umask");
        assert(observed == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            label ~ ": isolated native control failed (wait status " ~ to!string(status) ~ ")");
    }

    private Memory memory() {
        return new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string text, line;
        while ((line = file.readln()).length) text ~= line;
        return text;
    }

    private void run(string source, Memory mem) {
        try { executeProgram(source, mem); }
        catch (YshError error) {
            assert(false, "umask test source:\n" ~ source ~ "\nfailed with: " ~ error.msg);
        }
    }

    private string directory() {
        auto path = buildPath(tempDir(), "ysh-d-umask-" ~ to!string(getpid()));
        assert(mkdir(path.toStringz(), octal!700) == 0);
        assert(chmod(path.toStringz(), octal!700) == 0);
        return path;
    }

    private mode_t permissions(string path) {
        stat_t information;
        assert(stat(path.toStringz(), &information) == 0, "stat failed: " ~ path);
        return information.st_mode & octal!777;
    }

    private void newNativeObjects(string base, string name, mode_t fileMode, mode_t directoryMode) {
        auto filePath = buildPath(base, name ~ "-file");
        auto descriptor = open(filePath.toStringz(), O_WRONLY | O_CREAT | O_EXCL, cast(mode_t)octal!666);
        assert(descriptor >= 0, "native open failed: " ~ filePath);
        assert(close(descriptor) == 0);
        auto directoryPath = buildPath(base, name ~ "-directory");
        assert(mkdir(directoryPath.toStringz(), octal!777) == 0);
        assert(permissions(filePath) == fileMode, "wrong native file mode: " ~ name);
        assert(permissions(directoryPath) == directoryMode, "wrong native directory mode: " ~ name);
    }

    unittest {
        isolated("umask kernel and fork/exec effects", {
            auto base = directory();
            scope (exit) rmdirRecurse(base);
            auto mem = memory();
            mem.declareLocal("umask_base", Value.str(base));
            nativeUmask(octal!77);
            run(`
                umask 0002
                echo from-builtin > "$umask_base/builtin-file"
                /usr/bin/touch "$umask_base/exec-file"
                /usr/bin/mkdir "$umask_base/exec-directory"
            `, mem);
            assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
            // Check the syscall's old-mask return, then restore the setter's
            // value. No production parser or cached shell state is an oracle.
            assert(nativeUmask(octal!27) == octal!2);
            assert(nativeUmask(octal!2) == octal!27);
            assert(kernelMask() == octal!2);
            assert(permissions(buildPath(base, "builtin-file")) == octal!664);
            assert(permissions(buildPath(base, "exec-file")) == octal!664);
            assert(permissions(buildPath(base, "exec-directory")) == octal!775);
            newNativeObjects(base, "caller", octal!664, octal!775);
            run("umask g-w,o-w", mem);
            assert(mem.lastStatus == 0 && kernelMask() == octal!22);
            newNativeObjects(base, "symbolic", octal!644, octal!755);
        });
    }

    unittest {
        isolated("umask source and subshell scope", {
            auto base = directory();
            scope (exit) rmdirRecurse(base);
            auto fixture = buildPath(base, "set-mask.grease");
            writeText(fixture, "umask 0027\n");
            auto mem = memory();
            mem.declareLocal("umask_base", Value.str(base));
            mem.declareLocal("umask_fixture", Value.str(fixture));
            run(`
                umask 0002
                source "$umask_fixture"
                echo sourced > "$umask_base/sourced-file"
                (umask 0077; echo child > "$umask_base/subshell-file";
                    /usr/bin/mkdir "$umask_base/subshell-directory")
                echo caller > "$umask_base/after-subshell-file"
            `, mem);
            assert(mem.lastStatus == 0 && kernelMask() == octal!27);
            assert(permissions(buildPath(base, "sourced-file")) == octal!640);
            assert(permissions(buildPath(base, "subshell-file")) == octal!600);
            assert(permissions(buildPath(base, "subshell-directory")) == octal!700);
            assert(permissions(buildPath(base, "after-subshell-file")) == octal!640);
            newNativeObjects(base, "after-source", octal!640, octal!750);
            assert(contents(mem.errorFile) == "");
        });
    }

    unittest {
        isolated("umask ordinary errors are atomic", {
            auto base = directory();
            scope (exit) rmdirRecurse(base);
            foreach (source; ["umask ''", "umask ' '", "umask b=rwx", "umask u",
                    "umask 'u+r,,u-r'", "umask 'u+r,q'", "umask 089", "umask 0x22",
                    "umask 022L", "umask 0o", "umask 0_22", "umask -- -1"]) {
                nativeUmask(octal!124);
                auto mem = memory();
                run(source, mem);
                assert(mem.lastStatus == 1 && kernelMask() == octal!124, source);
                assert(contents(mem.outputFile) == "" && contents(mem.errorFile).length != 0, source);
            }
            newNativeObjects(base, "after-error", octal!642, octal!653);
            foreach (source; ["umask 0000 0777", "umask u=, g+, o-", "umask -rwx",
                    "umask -wx", "umask -=+", "umask --help", "umask 0000 -S", "umask -S0022"]) {
                nativeUmask(octal!124);
                auto mem = memory();
                run(source, mem);
                assert(mem.lastStatus == 2 && kernelMask() == octal!124, source);
                assert(contents(mem.outputFile) == "" && contents(mem.errorFile).length != 0, source);
                if (source == "umask -S0022")
                    assert(contents(mem.errorFile).indexOf("flag -Z") >= 0);
            }
        });
    }

    unittest {
        isolated("umask symbolic original snapshot", {
            struct Case { mode_t initial; string operand; mode_t expected; }
            foreach (item; [
                    Case(octal!124, "a=,a=u", octal!111),
                    Case(octal!124, "a+x,a=X", octal!666),
                    Case(octal!246, "a-x,a+X", octal!357),
                    Case(octal!124, "a=u", octal!111),
                    Case(octal!365, "a=g", octal!666),
                    Case(octal!124, "a=o", octal!444),
                    Case(0, "u=r,g=w,o=x", octal!356),
                    Case(octal!777, "u+r,g+w,o+x", octal!356),
                    Case(octal!137, "u=,g+,o-", octal!737),
                    Case(octal!111, "u=rwx,u=rw,u=r,u=,g=rwx", octal!701),
                    Case(octal!124, "u+r+w+x", octal!24),
                    Case(octal!124, "a+ugorwx", 0),
                    Case(octal!124, "=rx", octal!222),
                    Case(octal!124, "a+s+t", octal!124),
                    Case(octal!124, "a=st", octal!777),
                    Case(octal!124, "=+=", octal!777),
                    Case(octal!124, "+", octal!124),
                    Case(octal!124, "-", octal!124),
                    Case(octal!124, "-- -r", octal!564)]) {
                nativeUmask(item.initial);
                auto mem = memory();
                run("umask " ~ item.operand, mem);
                assert(mem.lastStatus == 0 && kernelMask() == item.expected, item.operand);
                assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "", item.operand);
            }
            nativeUmask(octal!124);
            auto mem = memory();
            run("umask a=; umask a=u", mem);
            assert(mem.lastStatus == 0 && kernelMask() == octal!777,
                "separate invocations must take separate permission-copy snapshots");
        });
    }

    unittest {
        isolated("umask numeric grammar and signed bounds", {
            struct Case { string operand; mode_t expected; }
            foreach (item; [Case("0000", 0), Case("0777", octal!777),
                    Case("1234567", octal!567), Case("0o22", octal!22),
                    Case("0O33", octal!33), Case("+022", octal!22),
                    Case("' +0O044 \t'", octal!44), Case("-- -2", octal!776),
                    Case("-- -0", 0), Case("-- -20000000000", 0),
                    Case("17777777777", octal!777), Case("-S 0022", octal!22)]) {
                nativeUmask(octal!124);
                auto mem = memory();
                run("umask " ~ item.operand, mem);
                assert(mem.lastStatus == 0 && kernelMask() == item.expected, item.operand);
                assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "", item.operand);
            }
            foreach (operand; ["20000000000", "-- -20000000001",
                    "777777777777777777777777777777777777777777777777777777777777777"]) {
                nativeUmask(octal!124);
                auto mem = memory();
                bool failed;
                try { executeProgram("umask " ~ operand ~ "; echo wrong-return", mem); }
                catch (FatalRuntimeError error) { failed = error.status == 1; }
                assert(failed && kernelMask() == octal!124 && contents(mem.outputFile) == "", operand);
            }
        });
    }

    unittest {
        isolated("umask getter flags and format", {
            foreach (source; ["umask", "umask -S", "umask -p", "umask -pS", "umask -SSppS", "umask --"]) {
                nativeUmask(octal!124);
                auto mem = memory();
                run(source, mem);
                assert(mem.lastStatus == 0 && kernelMask() == octal!124, source);
                assert(contents(mem.outputFile) == "0124\n" && contents(mem.errorFile) == "", source);
            }
            foreach (item; [tuple(0, "0000\n"), tuple(octal!7, "0007\n"), tuple(octal!777, "0777\n")]) {
                nativeUmask(item[0]);
                auto mem = memory();
                run("umask", mem);
                assert(mem.lastStatus == 0 && kernelMask() == item[0]);
                assert(contents(mem.outputFile) == item[1]);
            }
        });
    }

    unittest {
        isolated("umask typed evaluation before rejection", {
            nativeUmask(octal!124);
            auto mem = memory();
            mem.options.set("ysh:all", true);
            run(`
                var calls = 0
                func argument() { setglobal calls += 1; return (42) }
                try { umask 0000 (argument(); named=argument()) { error 'block ran' } }
                assert [_error.code === 2]
                assert [calls === 2]
                try { builtin umask 0000 (argument()) }
                assert [_error.code === 2]
                try { command umask 0000 (; named=argument()) }
                assert [_error.code === 2]
                assert [calls === 4]
                try { umask 0000 [unbound] }
                assert [_error.code === 2]
                try { umask 0000 [argument()] }
                assert [_error.code === 2]
                assert [calls === 4]
                try { umask 0000 { error 'block ran' } }
                assert [_error.code === 2]
                try { umask 0000 (1 / 0) }
                assert [_error.code === 3]
            `, mem);
            assert(mem.lastStatus == 0 && kernelMask() == octal!124);
            assert(mem.get("calls").integerValue == 4 && contents(mem.outputFile) == "");
            foreach (source; ["umask 0000 (unbound)", "umask 0000 (; named=unbound)"]) {
                bool failed;
                try { executeProgram(source, mem); }
                catch (FatalRuntimeError error) { failed = error.status == 1; }
                assert(failed && kernelMask() == octal!124, source);
            }
        });
    }

    unittest {
        isolated("umask query output errors preserve kernel mask", {
            foreach (source; ["umask >/dev/full", "umask >&-"]) {
                nativeUmask(octal!124);
                auto mem = memory();
                auto output = mem.outputFile;
                run(source, mem);
                assert(mem.lastStatus == 1 && kernelMask() == octal!124, source);
                assert(contents(output) == "" && contents(mem.errorFile).length != 0, source);
                run("echo restored", mem);
                assert(mem.lastStatus == 0 && contents(output) == "restored\n");
            }
        });
    }
}
