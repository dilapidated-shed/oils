module yshd.dispatch_test;

version (unittest) {
    import std.stdio : File;
    import yshd.state : Memory;
    import yshd.program : executeProgram;
    import yshd.printf_osh : runPrintf;
    import yshd.value : UsageError;

    private string contents(File file) {
        file.rewind();
        string text, line;
        while ((line = file.readln()).length) text ~= line;
        return text;
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        executeProgram(`
            echo() { builtin echo function "$@"; }
            echo local
            command echo native
            builtin echo builtin
            prefix=command
            $prefix echo 'literal; false'
            prefix=''
            $prefix command echo empty
            command() { builtin echo replacement; }
            command echo ignored
            builtin command echo bypass
        `, mem);
        assert(contents(mem.outputFile) == "function local\nnative\nbuiltin\nliteral; false\nempty\nreplacement\nbypass\n");
        assert(mem.lastStatus == 0);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var calls = 0
            func argument() { setglobal calls += 1; return (42) }
            proc consume (; value) { assert [value === 42] }
            runproc consume (argument())
            invoke --proc consume (argument())
            assert [calls === 2]
            builtin cd / { assert [calls === 2] }
            command cd / { assert [calls === 2] }
            var text = ''
            builtin read --all (&text) <<< input
            assert [text === b'input\n']
        `, mem);
        assert(mem.lastStatus == 0);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        assert(runPrintf(["%s %d\\n", "value", "42"], mem) == 0);
        assert(runPrintf(["[%*s]\\n", "-3", "x"], mem) == 0);
        assert(runPrintf(["\\000\\101%s", "tail"], mem) == 0);
        assert(runPrintf(["%b", "a\\7b\\cignored"], mem) == 0);
        assert(contents(mem.outputFile) == "value 42\n[x]\n\0Ataila\x07b");
        // All format fields are checked before writing, including later ones.
        mem.outputFile = File.tmpfile();
        bool failed;
        try { runPrintf(["prefix %s %f", "x", "1.0"], mem); }
        catch (UsageError error) { failed = true; }
        assert(failed && contents(mem.outputFile) == "");
        assert(runPrintf(["-v", "broken[", "%s", "value"], mem) == 2);
        executeProgram("i=1; declare -a values; printf -v 'values[i++]' %s 'kept text'", mem);
        assert(mem.wordVariable("i") == "2");
        assert(mem.get("values").shellContainer.get("1").stringValue == "kept text");
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        mem.initializeShellEnvironment();
        executeProgram("export DISPATCH_TEST_VALUE=first; DISPATCH_TEST_VALUE=second", mem);
        assert(mem.childEnvironment()["DISPATCH_TEST_VALUE"] == "second");
        executeProgram("export -n DISPATCH_TEST_VALUE", mem);
        assert("DISPATCH_TEST_VALUE" !in mem.childEnvironment());
        assert(mem.wordVariable("DISPATCH_TEST_VALUE") == "second");
        executeProgram("unset DISPATCH_TEST_VALUE; PATH=/chosen/path", mem);
        assert(mem.getEnv("PATH") == "/chosen/path");
        executeProgram("unset PATH", mem);
        assert(mem.getEnv("PATH", "missing") == "missing");
    }
}
