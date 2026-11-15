module yshd.diagnostic_io_test;

version (unittest) {
    import core.stdc.errno : errno, EBADF, EINTR, ENOSPC;
    import core.sys.posix.sys.stat : nativeUmask = umask;
    import core.sys.posix.sys.types : mode_t;
    import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
    import core.sys.posix.unistd : fork, _exit;
    import std.conv : octal, to;
    import std.exception : ErrnoException;
    import std.stdio : File, stderr;
    import std.string : indexOf;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : FatalRuntimeError;

    private mode_t kernelMask() {
        auto previous = nativeUmask(0);
        nativeUmask(previous);
        return previous;
    }

    private void isolated(string label, void delegate() body) {
        auto before = kernelMask();
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            try { body(); }
            catch (Throwable error) { stderr.writeln(label, ": ", error); _exit(91); }
            _exit(0);
        }
        int status, observed;
        do { observed = waitpid(child, &status, 0); }
        while (observed < 0 && errno == EINTR);
        assert(kernelMask() == before, label ~ ": changed parent runner mask");
        assert(observed == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            label ~ ": isolated native control failed");
    }

    private Memory memory() {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        return mem;
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string text, line;
        while ((line = file.readln()).length) text ~= line;
        return text;
    }

    unittest {
        isolated("strict builtin diagnostic stream", {
            auto mem = memory();
            mem.writeDiagnostic("completed");
            assert(contents(mem.errorFile) == "completed\n");
            foreach (closed; [false, true]) {
                mem.errorFile = closed ? File.init : File("/dev/full", "w");
                bool failed;
                try { mem.writeDiagnostic("must reach the diagnostic sink now"); }
                catch (ErrnoException error) {
                    failed = error.errno == (closed ? EBADF : ENOSPC);
                }
                assert(failed, "builtin reporting swallowed a failed diagnostic sink");
            }
        });
    }

    unittest {
        isolated("try distinguishes failed reporting from shell failure", {
            struct Case {
                string command;
                string expected;
                mode_t mask;
                string diagnostic;
            }
            foreach (item; [
                    Case("try { umask 'u+r,q' 2>/dev/full }", "status=1 error=17\n0000\n", 0, "try builtin I/O error"),
                    Case("try { umask 'u+r,q' 2>&- }", "status=1 error=17\n0000\n", 0, "try builtin I/O error"),
                    Case("try { umask >/dev/full 2>/dev/full }", "status=1 error=17\n0124\n", octal!124, "try builtin I/O error"),
                    Case("try { umask >&- 2>/dev/full }", "status=1 error=17\n0124\n", octal!124, "try builtin I/O error"),
                    Case("try { umask >/dev/full 2>&- }", "status=1 error=17\n0124\n", octal!124, "try builtin I/O error"),
                    Case("try { umask --help 2>/dev/full }", "status=1 error=17\n0124\n", octal!124, "try builtin I/O error"),
                    Case("try { printf -Q 2>/dev/full }", "status=1 error=17\n0124\n", octal!124, "try builtin I/O error"),
                    Case("try { printf '%s' text >/dev/full 2>/dev/full }", "status=1 error=17\n0124\n", octal!124, "try builtin I/O error"),
                    Case("try { times >/dev/full 2>/dev/full }", "status=1 error=17\n0124\n", octal!124, "try builtin I/O error"),
                    Case("try { umask >/dev/full }", "status=0 error=1\n0124\n", octal!124, "umask builtin I/O error"),
                    Case("try { umask >&- }", "status=0 error=1\n0124\n", octal!124, "umask builtin I/O error"),
                    Case("try { umask --help }", "status=0 error=2\n0124\n", octal!124, "doesn't accept flag"),
                    Case("try { printf '%s' text >/dev/full }", "status=0 error=1\n0124\n", octal!124, "printf builtin I/O error")]) {
                nativeUmask(octal!124);
                auto mem = memory();
                executeProgram("set +o errexit; try { error previous (code=17) }; " ~
                    item.command ~ "; echo status=$? error=$[_error.code]; umask", mem);
                assert(mem.lastStatus == 0 && kernelMask() == item.mask, item.command);
                assert(contents(mem.outputFile) == item.expected, item.command ~ "\n" ~ contents(mem.outputFile));
                assert(contents(mem.errorFile).indexOf(item.diagnostic) >= 0, item.command);
            }
        });
    }

    unittest {
        isolated("nested try restores the correct I/O boundary", {
            nativeUmask(octal!124);
            auto mem = memory();
            executeProgram(`
                set +o errexit
                try { error previous (code=17) }
                try {
                    try { umask 'u+r,q' 2>/dev/full }
                    echo wrong
                }
                echo status=$? error=$[_error.code]
                umask
            `, mem);
            assert(contents(mem.outputFile) == "status=0 error=1\n0000\n");
            assert(kernelMask() == 0 && mem.lastStatus == 0);
            assert(contents(mem.errorFile).indexOf("try builtin I/O error") >= 0);

            nativeUmask(octal!124);
            mem = memory();
            executeProgram(`
                set +o errexit
                try { error previous (code=17) }
                try {
                    try { umask 'u+r,q' 2>/dev/full } 2>/dev/full
                    echo wrong
                }
                echo status=$? error=$[_error.code]
                umask
            `, mem);
            assert(contents(mem.outputFile) == "status=1 error=17\n0000\n");
            assert(kernelMask() == 0 && mem.lastStatus == 0);
            assert(contents(mem.errorFile).indexOf("try builtin I/O error") >= 0);
        });
    }

    unittest {
        isolated("builtin stdout flushing preserves an earlier error", {
            // The reference always flushes stdout, but a flush failure must
            // not replace a body exception or an early error-handler return.
            auto mem = memory();
            mem.errexit = false;
            mem.outputFile = File("/dev/full", "w");
            mem.outputFile.write("buffered before the body error");
            executeProgram("umask --help", mem);
            assert(mem.lastStatus == 2);
            assert(contents(mem.errorFile).indexOf("builtin I/O error") < 0);

            mem = memory();
            mem.errexit = false;
            mem.outputFile = File("/dev/full", "w");
            mem.outputFile.write("buffered before the escaping exception");
            bool failed;
            try { executeProgram("umask 20000000000", mem); }
            catch (FatalRuntimeError error) { failed = error.status == 1; }
            assert(failed && contents(mem.errorFile) == "");
        });
    }

    unittest {
        isolated("parsed data builtins retain the VM I/O boundary", {
            foreach (command; ["json write (42)", "json8 write (42)", "pp value (42)",
                    "pp test_ (42)", "pp asdl_ (42)", "pp cell_ retained", "pp frame_vars_"]) {
                struct Sink { string redirect; string expected; string marker; }
                foreach (sink; [
                        Sink(">/dev/full", "status=0 error=1\n", "builtin I/O error"),
                        Sink(">&-", "status=0 error=1\n", "builtin I/O error"),
                        Sink(">/dev/full 2>/dev/full", "status=1 error=17\n", "try builtin I/O error"),
                        Sink(">&- 2>&-", "status=1 error=17\n", "try builtin I/O error")]) {
                    auto mem = memory();
                    executeProgram("set +o errexit; var retained = 42; try { error previous (code=17) }; " ~
                        "try { " ~ command ~ " " ~ sink.redirect ~ " }; echo status=$? error=$[_error.code]", mem);
                    assert(mem.lastStatus == 0 && contents(mem.outputFile) == sink.expected,
                        command ~ " " ~ sink.redirect ~ "\n" ~ contents(mem.outputFile));
                    assert(contents(mem.errorFile).indexOf(sink.marker) >= 0, command ~ " " ~ sink.redirect);
                }
            }
            foreach (command; ["json write (1 / 0)", "json8 write (1 / 0)", "pp value (1 / 0)",
                    "json invalid (1 / 0)", "pp invalid (1 / 0)", "json write ('text'; space='invalid')"]) {
                auto mem = memory();
                executeProgram("set +o errexit; try { error previous (code=17) }; try { " ~ command ~
                    " >/dev/full 2>/dev/full }; echo status=$? error=$[_error.code]", mem);
                assert(contents(mem.outputFile) == "status=0 error=3\n", command);
                assert(contents(mem.errorFile) == "", command ~ ": output failure replaced an earlier typed error");
            }
            foreach (command; ["json read <<< 'invalid'", "json8 read <<< 'invalid'", "pp cell_ absent",
                    "json write (1..<3)", "json8 write (1..<3)"]) {
                auto mem = memory();
                executeProgram("set +o errexit; try { error previous (code=17) }; try { " ~ command ~
                    " 2>/dev/full }; echo status=$? error=$[_error.code]", mem);
                assert(contents(mem.outputFile) == "status=1 error=17\n", command);
                assert(contents(mem.errorFile).indexOf("try builtin I/O error") >= 0, command);
            }
        });
    }
}
