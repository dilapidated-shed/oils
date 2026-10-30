module yshd.trace_test;

version (unittest) {
    import std.stdio : File;
    import yshd.program : executeProgram, ShellExit;
    import yshd.state : Memory;
    import yshd.trace : maybeShellQuote;

    private string contents(File file) {
        file.rewind();
        string result;
        while (!file.eof()) result ~= file.readln();
        return result;
    }

    unittest {
        assert(maybeShellQuote("alpha-1/file") == "alpha-1/file");
        assert(maybeShellQuote("true") == "'true'");
        assert(maybeShellQuote("") == "''");
        assert(maybeShellQuote("two words") == "'two words'");
        assert(maybeShellQuote("μ") == "'μ'");
        assert(maybeShellQuote("\xfe") == "$'\\xfe'");
        assert(maybeShellQuote("line\n") == "$'line\\n'");

        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(output, errors);
        mem.options.set("ysh:upgrade", true);
        mem.errexit = false;
        executeProgram(`
            proc p (word) { echo $word }
            set -x
            p 'two words'
            eval 'echo nested'
            set +x
            echo final
        `, mem);
        assert(contents(output) == "two words\nnested\nfinal\n");
        assert(contents(errors) ==
            "> proc p 'two words'\n  . builtin echo 'two words'\n< proc p\n" ~
            "> eval\n  . builtin echo nested\n< eval\n. builtin set '+x'\n");
    }

    unittest {
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(output, errors);
        mem.options.set("ysh:upgrade", true);
        mem.errexit = false;
        executeProgram(`
            PS4='$(echo p)$? '
            set -o xtrace
            false
            echo status=$?
            set +o xtrace
        `, mem);
        assert(contents(output) == "status=1\n");
        assert(contents(errors) ==
            "p0 builtin 'false'\np1 builtin echo 'status=1'\np0 builtin set '+o' xtrace\n");
        assert(mem.getCell("SHX_indent") is null);
        assert(mem.getCell("SHX_punct") is null);
        assert(mem.getCell("SHX_pid_str") is null);
        assert(!mem.options.get("xtrace"));
    }

    unittest {
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(output, errors);
        mem.options.set("ysh:upgrade", true);
        mem.errexit = false;
        // A failed prefix substitution is a plugin error, not permission to
        // abort or change the status of the command being traced.
        executeProgram("PS4='$(exit 7) '; set -x; echo one; set +x", mem);
        assert(mem.lastStatus == 0);
        assert(contents(output) == "one\n");
        assert(contents(errors) ==
            "<Runtime error: Command Sub exited with status 7>builtin echo one\n" ~
            "<Runtime error: Command Sub exited with status 7>builtin set '+x'\n");
    }

    unittest {
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(output, errors);
        executeProgram("set -x; echo 'two words'; set +x; echo after", mem);
        assert(contents(output) == "two words\nafter\n");
        assert(contents(errors) == "+ echo 'two words'\n+ set '+x'\n");

        auto richErrors = File.tmpfile();
        mem = new Memory(File.tmpfile(), richErrors);
        mem.options.set("ysh:upgrade", true);
        bool exited;
        try { executeProgram("set -x; eval 'exit 9'", mem); }
        catch (ShellExit control) { exited = control.status == 9; }
        assert(exited);
        executeProgram("echo after", mem);
        assert(contents(richErrors) ==
            "> eval\n  + exit 9\n< eval\n. builtin echo after\n");
    }
}
