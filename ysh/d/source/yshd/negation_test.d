module yshd.negation_test;

version (unittest) {
    import std.stdio : File;
    import yshd.program : executeProgram, parseProgram;
    import yshd.options : ShellOptions;
    import yshd.state : Memory, ReturnMode;
    import yshd.value : YshError;

    unittest {
        // These are runtime strict_errexit refusals, not parse failures.
        foreach (source; [
            "! true | false",
            "! { echo hidden; false; } >/dev/null; echo unreachable",
            "! if false; then echo hidden; fi",
            "! exit 91",
        ]) {
            auto output = File.tmpfile();
            auto mem = new Memory(output, File.tmpfile());
            mem.options.set("ysh:all", true);
            parseProgram(source, ReturnMode.shell, mem.options);
            bool rejected;
            try { executeProgram(source, mem); }
            catch (YshError error) {
                import std.string : indexOf;
                rejected = error.status == 1 && error.msg.indexOf("strict_errexit") >= 0;
            }
            assert(rejected, source);
            output.rewind();
            assert(output.readln().length == 0, source);
        }
    }

    unittest {
        foreach (disable; ["errexit", "strict_errexit"]) {
            auto output = File.tmpfile();
            auto mem = new Memory(output, File.tmpfile());
            mem.options.set("ysh:all", true);
            mem.options.set(disable, false);
            executeProgram("! true | false; echo pipeline=$?; ! { false; } >/dev/null; echo brace=$?", mem);
            output.rewind();
            assert(output.readln() == "pipeline=0\n");
            assert(output.readln() == "brace=0\n");
            assert(output.readln().length == 0);
        }
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.options.set("no_parse_dbracket", false);
        executeProgram("! true >/dev/null; echo simple=$?; ! [[ a == a ]]; echo bracket=$?; ! test '|' = '|'; echo word=$?", mem);
        output.rewind();
        assert(output.readln() == "simple=1\n");
        assert(output.readln() == "bracket=1\n");
        assert(output.readln() == "word=1\n");
    }

    unittest {
        auto options = new ShellOptions(true);
        foreach (source; [
            "! exit 91 >/dev/null; if ! false >/dev/null 2>&1; then exit 92; fi",
            "return 7 >/dev/null",
            "break >/dev/null",
            "continue >/dev/null",
            ">/dev/null exit 91",
        ]) {
            bool rejected;
            try { parseProgram(source, ReturnMode.shell, options); }
            catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
            parseProgram(source, ReturnMode.shell, new ShellOptions());
        }
        parseProgram("'exit' 91 >/dev/null", ReturnMode.shell, options);
        parseProgram("exit-helper >/dev/null", ReturnMode.shell, options);

        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.nounset = true;
        executeProgram("f() { return 7 >$undefined; }; f; echo status=$?", mem);
        output.rewind();
        assert(output.readln() == "status=7\n");
        executeProgram("for word in a b; do break >$undefined; done", mem);
        assert(mem.get("word").stringValue == "a");
    }
}
