module yshd.dispatch_test;

version (unittest) {
    import std.stdio : File;
    import yshd.state : Cell, Memory;
    import yshd.program : executeProgram;
    import yshd.printf_osh : runPrintf;
    import yshd.value : UsageError, Value, ValueKind, YshError;

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

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.initializeShellEnvironment();
        auto env = mem.get("ENV").dictValue;
        env.set("NATIVE_ENV_STRING", Value.str("kept"));
        env.set("NATIVE_ENV_EMPTY", Value.str(""));
        env.set("NATIVE_ENV_NULL", Value.nullValue());
        env.set("NATIVE_ENV_INTEGER", Value.integer(42));
        env.set("NATIVE_ENV_BOOLEAN", Value.boolean(false));
        env.set("NATIVE_ENV_LIST", Value.list([Value.str("not exported")]));
        env.set("NATIVE_ENV_DICT", Value.dict());
        auto child = mem.childEnvironment();
        assert(child["NATIVE_ENV_STRING"] == "kept");
        assert("NATIVE_ENV_EMPTY" in child && child["NATIVE_ENV_EMPTY"] == "");
        foreach (name; ["NATIVE_ENV_NULL", "NATIVE_ENV_INTEGER", "NATIVE_ENV_BOOLEAN", "NATIVE_ENV_LIST", "NATIVE_ENV_DICT"])
            assert(name !in child);
        assert(env.get("NATIVE_ENV_NULL").kind == ValueKind.nullValue);
        assert(env.get("NATIVE_ENV_INTEGER").integerValue == 42);
        assert(env.get("NATIVE_ENV_LIST").listValue.length == 1);

        // GetEnv fills exported cells first, then overlays only ENV strings.
        mem.options.set("no_exported", false);
        auto exported = new Cell(Value.str("exported"));
        exported.exported = true;
        mem.globalFrame.cells.set("NATIVE_ENV_SHADOW", exported);
        env.set("NATIVE_ENV_SHADOW", Value.nullValue());
        assert(mem.childEnvironment()["NATIVE_ENV_SHADOW"] == "exported");
        env.set("NATIVE_ENV_SHADOW", Value.str("overlay"));
        assert(mem.childEnvironment()["NATIVE_ENV_SHADOW"] == "overlay");
        mem.options.set("env_obj", false);
        assert(mem.childEnvironment()["NATIVE_ENV_SHADOW"] == "exported");
        assert("NATIVE_ENV_STRING" !in mem.childEnvironment());
        mem.options.set("env_obj", true);
        bool scalarRejected;
        try { mem.getEnv("NATIVE_ENV_NULL"); }
        catch (YshError error) { scalarRejected = true; }
        assert(scalarRejected);
    }
}
