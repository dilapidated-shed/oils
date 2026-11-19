module yshd.getopts_test;

version (unittest) {
    import std.bigint : BigInt;
    import std.stdio : File;
    import yshd.getopts : runGetOpts;
    import yshd.program : executeProgram;
    import yshd.state : Cell, Frame, Memory, ShellArgumentFrame;
    import yshd.value : FatalRuntimeError, InterpreterFailure, UsageError, Value, ValueKind, YshDict, YshError;

    private Memory memory() {
        return new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string result, line;
        while ((line = file.readln()).length) result ~= line;
        return result;
    }

    private void selected(Memory mem, string index, string option, string argument, string name = "opt") {
        assert(mem.get("OPTIND").kind == ValueKind.stringValue);
        assert(mem.get("OPTIND").stringValue == index);
        assert(mem.get(name).kind == ValueKind.stringValue);
        assert(mem.get(name).stringValue == option);
        assert(mem.get("OPTARG").kind == ValueKind.stringValue);
        assert(mem.get("OPTARG").stringValue == argument);
    }

    // These are literal retained-GetOpts outcomes, independent of libc getopt,
    // another shell, and host command-line parsing.
    unittest {
        auto mem = memory();
        assert(mem.get("OPTIND").stringValue == "1");
        assert(mem.getCell("OPTARG") is null && mem.getCell("OPTERR") is null);
        mem.initializeArguments("zero", ["-abc", "operand"]);
        auto frame = mem.shellArgumentFrame;
        assert(runGetOpts(["abc", "opt"], mem) == 0);
        selected(mem, "1", "a", "");
        assert(runGetOpts(["abc", "opt"], mem) == 0);
        selected(mem, "1", "b", "");
        assert(runGetOpts(["abc", "opt"], mem) == 0);
        selected(mem, "2", "c", "");
        foreach (unused; 0 .. 2) {
            assert(runGetOpts(["abc", "opt"], mem) == 1);
            selected(mem, "2", "?", "");
        }
        assert(mem.shellArgumentFrame is frame && mem.shellArguments == ["-abc", "operand"]);
        assert(mem.shellArgument(0) == "zero" && mem.get("ARGV").listValue.length == 2);
        assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "");
    }

    unittest {
        auto mem = memory();
        auto words = ["ab:c:", "opt", "-ab", "hi", "-c", "hello"];
        assert(runGetOpts(words, mem) == 0);
        selected(mem, "1", "a", "");
        assert(runGetOpts(words, mem) == 0);
        selected(mem, "3", "b", "hi");
        assert(runGetOpts(words, mem) == 0);
        selected(mem, "5", "c", "hello");
        assert(runGetOpts(words, mem) == 1);
        selected(mem, "5", "?", "");

        mem = memory();
        words = ["abc:", "opt", "-abc10"];
        assert(runGetOpts(words, mem) == 0);
        selected(mem, "1", "a", "");
        assert(runGetOpts(words, mem) == 0);
        selected(mem, "1", "b", "");
        assert(runGetOpts(words, mem) == 0);
        selected(mem, "2", "c", "10");
        assert(mem.getoptsFlagPosition == 1);
        assert(runGetOpts(words, mem) == 1);
        selected(mem, "2", "?", "");
    }

    unittest {
        foreach (argument; ["", "-", "--", "-b", "two words", "\0raw"]) {
            auto mem = memory();
            assert(runGetOpts(["a:", "opt", "-a", argument], mem) == 0);
            selected(mem, "3", "a", argument);
        }
        auto mem = memory();
        mem.initializeArguments("zero", ["-a", "from positionals"]);
        auto argv = mem.get("ARGV").listValue;
        assert(runGetOpts(["a:", "opt", "-aexplicit"], mem) == 0);
        selected(mem, "2", "a", "explicit");
        assert(mem.shellArguments == ["-a", "from positionals"]);
        assert(mem.get("ARGV").listValue is argv);
    }

    unittest {
        foreach (operand; ["", "-", "operand", "+a"]) {
            auto mem = memory();
            mem.setGlobal("OPTARG", Value.str("old"));
            assert(runGetOpts([":a", "opt", operand, "-a"], mem) == 1);
            selected(mem, "1", "?", "");
            assert(runGetOpts(["a", "opt", operand, "-a"], mem) == 1);
            selected(mem, "1", "?", "");
        }
        auto mem = memory();
        mem.setGlobal("OPTARG", Value.str("preserved"));
        assert(runGetOpts(["a", "opt", "--", "-a"], mem) == 1);
        selected(mem, "2", "?", "preserved");
        // '--' terminates this invocation, rather than installing a permanent
        // end-of-options bit. An explicit following invocation resumes.
        assert(runGetOpts(["a", "opt", "--", "-a"], mem) == 0);
        selected(mem, "3", "a", "");
    }

    unittest {
        auto mem = memory();
        auto words = ["a", "opt", "-Za"];
        assert(runGetOpts(words, mem) == 0);
        selected(mem, "1", "?", "");
        assert(contents(mem.errorFile) == "getopts: invalid flag -Z\n");
        assert(runGetOpts(words, mem) == 0);
        selected(mem, "2", "a", "");

        mem = memory();
        assert(runGetOpts([":a", "opt", "-Z"], mem) == 0);
        selected(mem, "2", "?", "Z");
        assert(contents(mem.errorFile) == "");

        mem = memory();
        assert(runGetOpts(["a:", "opt", "-a"], mem) == 0);
        selected(mem, "2", "?", "");
        assert(contents(mem.errorFile) == "getopts: flag -a requires an argument\n");
        mem = memory();
        assert(runGetOpts([":a:", "opt", "-a"], mem) == 0);
        selected(mem, "2", ":", "a");
        assert(contents(mem.errorFile) == "");
    }

    unittest {
        foreach (text; ["0", "-0", "+000", " \t000\n"]) {
            auto mem = memory();
            mem.setGlobal("OPTERR", Value.str(text));
            assert(runGetOpts(["a", "opt", "-Z"], mem) == 0);
            selected(mem, "2", "?", "");
            assert(contents(mem.errorFile) == "");
        }
        foreach (value; [Value.str("broken"), Value.str("1_0"), Value.integer(0),
                Value.nullValue(), Value.list([]), Value.str("99999999999999999999999999999")]) {
            auto mem = memory();
            mem.setGlobal("OPTERR", value);
            assert(runGetOpts(["a", "opt", "-Z"], mem) == 0);
            assert(contents(mem.errorFile) == "getopts: invalid flag -Z\n");
        }
    }

    unittest {
        // Duplicate spec entries overwrite their earlier argument bit.
        auto mem = memory();
        assert(runGetOpts(["a:a", "opt", "-ab"], mem) == 0);
        selected(mem, "1", "a", "");
        mem = memory();
        assert(runGetOpts(["aa:", "opt", "-ab"], mem) == 0);
        selected(mem, "2", "a", "b");
        mem = memory();
        assert(runGetOpts(["::", "opt", "-:"], mem) == 0);
        selected(mem, "2", ":", "");
        mem = memory();
        assert(runGetOpts([":::", "opt", "-:attached"], mem) == 0);
        selected(mem, "2", ":", "attached");
        mem = memory();
        assert(runGetOpts(["?", "opt", "-?"], mem) == 0);
        selected(mem, "2", "?", "");
        assert(contents(mem.errorFile) == "");
    }

    unittest {
        // UTF-8's two bytes are two retained option characters.
        enum bytes = "\xc3\xa9";
        auto mem = memory();
        assert(runGetOpts([bytes, "opt", "-" ~ bytes], mem) == 0);
        selected(mem, "1", "\xc3", "");
        assert(runGetOpts([bytes, "opt", "-" ~ bytes], mem) == 0);
        selected(mem, "2", "\xa9", "");
        mem = memory();
        assert(runGetOpts(["\xff:", "opt", "-\xff\0\x80"], mem) == 0);
        selected(mem, "2", "\xff", "\0\x80");
    }

    unittest {
        auto mem = memory();
        assert(runGetOpts(["abc", "opt", "-abc"], mem) == 0);
        selected(mem, "1", "a", "");
        mem.setGlobal("OPTIND", Value.str("1"));
        assert(runGetOpts(["xyz", "opt", "-xyz"], mem) == 0);
        selected(mem, "1", "y", "");
        assert(mem.getoptsFlagPosition == 3);
        // A positional-frame change also does not own the option byte cursor.
        mem.shellArgumentFrame = new ShellArgumentFrame(["-xyz"]);
        assert(runGetOpts(["xyz", "opt"], mem) == 0);
        selected(mem, "2", "z", "");
        mem.setGlobal("OPTIND", Value.str("1"));
        assert(runGetOpts(["abc", "opt", "-abc"], mem) == 0);
        assert(mem.getoptsFlagPosition == 2);
        assert(runGetOpts(["a", "opt", "--"], mem) == 1);
        assert(mem.getoptsFlagPosition == 1 && mem.get("OPTIND").stringValue == "2");
    }

    unittest {
        auto mem = memory();
        assert(runGetOpts(["abc", "opt", "-abc"], mem) == 0);
        bool rejected;
        try { runGetOpts(["x", "opt", "-x"], mem); }
        catch (InterpreterFailure error) { rejected = true; }
        assert(rejected && mem.getoptsFlagPosition == 2);
        selected(mem, "1", "a", "");
        assert(contents(mem.errorFile) == "");
    }

    unittest {
        foreach (name; ["", "0opt", "opt-", "opt[0]", "opt.x", "\xc3\xa9", "opt\0x", "opt\n\n", "opt\nx"]) {
            auto mem = memory();
            bool rejected;
            try { runGetOpts(["c:", name, "-c", "foo"], mem); }
            catch (UsageError error) { rejected = error.status == 2; }
            assert(rejected);
            assert(mem.get("OPTIND").stringValue == "3" && mem.get("OPTARG").stringValue == "foo");
            assert(mem.getCell(name) is null);
        }
        foreach (name; ["opt", "_", "_9", "a0Z", "opt\n", "_\n", "a0Z\n"]) {
            auto mem = memory();
            assert(runGetOpts(["a", name, "-a"], mem) == 0);
            selected(mem, "2", "a", "", name);
        }
        foreach (words; [cast(string[])[], ["a"]]) {
            auto mem = memory();
            mem.setGlobal("OPTARG", Value.str("unchanged"));
            bool rejected;
            try { runGetOpts(words, mem); }
            catch (UsageError error) { rejected = error.status == 2; }
            assert(rejected && mem.get("OPTIND").stringValue == "1" && mem.get("OPTARG").stringValue == "unchanged");
            assert(mem.getoptsFlagPosition == 1);
        }
    }

    unittest {
        auto mem = memory();
        mem.setGlobal("opt", Value.str("old"));
        mem.getCell("OPTIND").readOnly = true;
        assert(runGetOpts(["ab", "opt", "-ab"], mem) == 0);
        selected(mem, "1", "a", "");
        bool rejected;
        try { runGetOpts(["ab", "opt", "-ab"], mem); }
        catch (FatalRuntimeError error) { rejected = error.status == 1; }
        assert(rejected && mem.getoptsFlagPosition == 2);
        selected(mem, "1", "a", "");
        mem.getCell("OPTIND").readOnly = false;
        assert(runGetOpts(["ab", "opt", "-ab"], mem) == 0);
        selected(mem, "2", "b", "");

        foreach (cluster; ["-ab", "-a"]) {
            mem = memory();
            mem.setGlobal("opt", Value.str("old"));
            mem.declareLocal("OPTARG", Value.str("readonly"), true);
            rejected = false;
            try { runGetOpts(["ab", "opt", cluster], mem); }
            catch (FatalRuntimeError error) { rejected = error.status == 1; }
            assert(rejected);
            assert(mem.get("opt").stringValue == "old" && mem.get("OPTARG").stringValue == "readonly");
            assert(mem.get("OPTIND").stringValue == (cluster == "-ab" ? "1" : "2"));
            assert(mem.getoptsFlagPosition == (cluster == "-ab" ? 2 : 1));
        }
        mem = memory();
        mem.declareLocal("opt", Value.str("readonly"), true);
        rejected = false;
        try { runGetOpts(["c:", "opt", "-c", "value"], mem); }
        catch (FatalRuntimeError error) { rejected = error.status == 1; }
        assert(rejected);
        selected(mem, "3", "readonly", "value");
    }

    unittest {
        // BuiltinSetString replaces mutable typed values and shell arrays.
        foreach (old; [Value.integer(42), Value.list([]), Value.dict(), Value.shellArray(new YshDict())]) {
            auto mem = memory();
            mem.setGlobal("opt", old);
            mem.setGlobal("OPTARG", old);
            assert(runGetOpts(["a", "opt", "-a"], mem) == 0);
            selected(mem, "2", "a", "");
        }
        auto mem = memory();
        assert(runGetOpts(["c:", "OPTARG", "-c", "value"], mem) == 0);
        assert(mem.get("OPTARG").stringValue == "c");
        mem = memory();
        assert(runGetOpts(["a", "OPTIND", "-a"], mem) == 0);
        assert(mem.get("OPTIND").stringValue == "a");
        assert(runGetOpts(["a", "opt", "-a"], mem) == 1);
        selected(mem, "a", "?", "");
        assert(contents(mem.errorFile) == "$OPTIND doesn't look like an integer, got 'a'\n");
    }

    unittest {
        struct BadIndex { Value value; string diagnostic; }
        auto cases = [
            BadIndex(Value.str(""), "$OPTIND doesn't look like an integer, got ''\n"),
            BadIndex(Value.str("1_0"), "$OPTIND doesn't look like an integer, got '1_0'\n"),
            BadIndex(Value.str("0x1"), "$OPTIND doesn't look like an integer, got '0x1'\n"),
            BadIndex(Value.str("1\0"), "$OPTIND doesn't look like an integer, got '1\\x00'\n"),
            BadIndex(Value.integer(1), "$OPTIND should be a string, got Int\n"),
            BadIndex(Value.list([]), "$OPTIND should be a string, got List\n"),
            BadIndex(Value.nullValue(), "$OPTIND should be a string, got Null\n"),
            BadIndex(Value.str("\xff"), "$OPTIND doesn't look like an integer, got '\\xff'\n")];
        foreach (item; cases) {
            auto mem = memory();
            mem.setGlobal("OPTIND", item.value);
            mem.setGlobal("OPTERR", Value.str("0"));
            mem.setGlobal("OPTARG", Value.str("old"));
            assert(runGetOpts([":a", "opt", "-a"], mem) == 1);
            assert(mem.get("opt").stringValue == "?" && mem.get("OPTARG").stringValue == "");
            assert(contents(mem.errorFile) == item.diagnostic);
        }
        auto mem = memory();
        mem.unsetLocal("OPTIND");
        assert(runGetOpts(["a", "opt", "-a"], mem) == 1);
        assert(contents(mem.errorFile) == "$OPTIND should be a string, got Undef\n");
        foreach (index; ["0", "-1", "-2", "99999999999999999999999999999999",
                "-99999999999999999999999999999999"]) {
            mem = memory();
            mem.setGlobal("OPTIND", Value.str(index));
            assert(runGetOpts(["a", "opt", "-a"], mem) == 1);
            selected(mem, index, "?", "");
            assert(contents(mem.errorFile) == "");
        }
        mem = memory();
        mem.setGlobal("OPTIND", Value.str(" \t+001\r\n"));
        assert(runGetOpts(["ab", "opt", "-ab"], mem) == 0);
        selected(mem, " \t+001\r\n", "a", "");
        assert(runGetOpts(["ab", "opt", "-ab"], mem) == 0);
        selected(mem, "2", "b", "");
    }

    unittest {
        auto mem = memory();
        mem.options.set("dynamic_scope", true);
        mem.setGlobal("opt", Value.str("global"));
        auto outer = new Frame();
        mem.pushFrame(outer);
        mem.declareLocal("OPTIND", Value.str("1"));
        mem.declareLocal("OPTARG", Value.str("outer"));
        mem.declareLocal("opt", Value.str("outer"));
        mem.pushFrame(new Frame());
        assert(runGetOpts(["ab", "opt", "-ab"], mem) == 0);
        assert(mem.currentFrame.cells.get("OPTIND") is null);
        assert(outer.cells.get("OPTIND").value.stringValue == "1");
        assert(outer.cells.get("opt").value.stringValue == "a");
        mem.popFrame();
        mem.popFrame();
        // OPTIND locals are restored by frames, but the byte cursor survives.
        assert(mem.get("OPTIND").stringValue == "1" && mem.getoptsFlagPosition == 2);
        assert(runGetOpts(["ab", "opt", "-ab"], mem) == 0);
        selected(mem, "2", "b", "");

        mem = memory();
        mem.options.set("dynamic_scope", false);
        mem.setGlobal("OPTARG", Value.str("global"));
        mem.setGlobal("opt", Value.str("global"));
        mem.pushFrame(new Frame());
        mem.declareLocal("OPTIND", Value.str("88"));
        mem.pushFrame(new Frame());
        assert(runGetOpts(["a", "opt", "-a"], mem) == 0);
        selected(mem, "2", "a", "");
        mem.popFrame();
        assert(mem.get("OPTIND").stringValue == "88");
        mem.popFrame();
        selected(mem, "1", "global", "global");

        // Lexical __E__ enclosure participates in both lookup and writes.
        mem = memory();
        mem.options.set("dynamic_scope", false);
        auto enclosed = new Frame();
        enclosed.cells.set("OPTIND", new Cell(Value.str("1")));
        enclosed.cells.set("opt", new Cell(Value.str("captured")));
        mem.pushEnclosed(enclosed);
        assert(runGetOpts(["a", "opt", "-a"], mem) == 0);
        assert(enclosed.cells.get("OPTIND").value.stringValue == "2");
        assert(enclosed.cells.get("opt").value.stringValue == "a");
        assert(mem.currentFrame.cells.get("OPTIND") is null);
    }

    unittest {
        auto mem = memory();
        mem.options.set("ysh:all", true);
        executeProgram(`
            var calls = 0
            func argument() { setglobal calls += 1; return (42) }
            getopts a opt -a (argument(); named=argument()) { error 'block ran' }
            assert [calls === 2]
            setglobal OPTIND = '1'
            builtin getopts a opt -a (argument())
            setglobal OPTIND = '1'
            command getopts a opt -a (; named=argument())
            assert [calls === 4]
            setglobal OPTIND = '1'
            getopts a opt -a [unbound]
            setglobal OPTIND = '1'
            getopts a opt -a [argument()]
            assert [calls === 4]
            setglobal OPTIND = '1'
            getopts a opt -a { error 'block ran' }
            setglobal OPTIND = '1'
            getopts a opt -a (;; ^(error 'block ran'))
        `, mem);
        assert(mem.lastStatus == 0 && mem.get("calls").integerValue == 4);
        selected(mem, "2", "a", "");
        assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "");

        mem.setGlobal("OPTIND", Value.str("1"));
        mem.setGlobal("OPTARG", Value.str("before"));
        mem.setGlobal("opt", Value.str("before"));
        bool rejected;
        try { executeProgram("getopts a opt -a (unbound)", mem); }
        catch (YshError error) { rejected = error.status == 1; }
        assert(rejected, "getopts skipped eager typed-argument evaluation");
        selected(mem, "1", "before", "before");
    }

    unittest {
        auto mem = memory();
        mem.options.set("ysh:all", true);
        executeProgram(`
            var calls = 0
            proc getopts { setglobal calls += 1 }
            getopts
            var name = 'getopts'
            $name
            builtin getopts a opt -a
            setglobal OPTIND = '1'
            command getopts b opt -b
            assert [calls === 2]
        `, mem);
        assert(mem.lastStatus == 0 && mem.get("calls").integerValue == 2);
        selected(mem, "2", "b", "");
        assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "");
    }

    version (Posix) unittest {
        import yshd.process : captureSource, runSourceJob, runSourcePipeline;

        int executeChild(string kind, Memory child) {
            if (kind == "consumer") return 0;
            // Install in the child itself: prepareSubProgram has already
            // discarded inherited traps by the time this callback runs.
            assert(child.traps.builtin(["--add", "EXIT"], true, "echo EXIT", child) == 0);
            if (kind == "other") throw new Exception("other failure");
            if (kind == "ordinary") child.declareLocal("opt", Value.str("readonly"), true);
            assert(runGetOpts(["abc", "opt", "-abc"], child) == 0);
            // Retain the real stale-cluster InterpreterFailure, rather than
            // throwing a stand-in exception from this process-boundary test.
            return runGetOpts(["x", "opt", "-x"], child);
        }

        struct FailureCase { string kind; int status; string diagnostic; }
        auto cases = [
            FailureCase("internal", 1, "ysh-d: internal interpreter failure: getopts: option byte index out of range\n"),
            FailureCase("ordinary", 1, "ysh-d: Can't assign to readonly value 'opt'\n"),
            FailureCase("other", 3, "ysh-d: other failure\n")];
        foreach (item; cases) {
            auto mem = memory();
            auto captured = captureSource(item.kind, mem, &executeChild, true);
            assert(captured.status == item.status && captured.stdoutText == "");
            assert(captured.stderrText == item.diagnostic);
            assert(mem.getoptsFlagPosition == 1 && mem.get("OPTIND").stringValue == "1");
            assert(mem.getCell("opt") is null && !mem.traps.hasActions());

            mem = memory();
            assert(runSourceJob([item.kind], mem, &executeChild, false) == item.status);
            assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == item.diagnostic);
            assert(mem.getoptsFlagPosition == 1 && mem.get("OPTIND").stringValue == "1");
            assert(!mem.traps.hasActions());

            mem = memory();
            mem.pipefail = true;
            assert(runSourcePipeline([item.kind, "consumer"], mem, &executeChild) == item.status);
            assert(mem.pipelineStatus == [item.status, 0]);
            assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == item.diagnostic);
            assert(mem.getoptsFlagPosition == 1 && mem.get("OPTIND").stringValue == "1");
            assert(!mem.traps.hasActions());
        }
    }
}
