module yshd.word_array_test;

unittest {
    import std.stdio : File;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : FatalRuntimeError;

    auto output = File.tmpfile();
    auto mem = new Memory(output, File.tmpfile());
    executeProgram(`set +u; echo before "${unset_array[@]}" after`, mem);
    output.rewind();
    assert(output.readln() == "before after\n");
    bool rejected;
    try { executeProgram(`set -u; echo "${unset_array[@]}"`, mem); }
    catch (FatalRuntimeError error) { rejected = true; }
    assert(rejected);
}

version (unittest) {
    import std.stdio : File;
    import std.exception : assertThrown;
    import yshd.state : Memory;
    import yshd.program : executeProgram, parseProgram;
    import yshd.expr : ParseError, validateExpression;
    import yshd.value : YshError;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var words = ['one two', 'three']
            var array = %(
                @words
                'literal; value'
                "not | end"
                $(printf '(%s)' 'x')
            )
            assert [array === ['one two', 'three', 'literal; value', 'not | end', '(x)']]
            assert [%() === :||]
            assert [7 % 3 === 1]
        `, mem);
        assert(mem.lastStatus == 0);
    }

    unittest {
        foreach (source; ["% (a)", "%(a | b)", "%(a; b)", "%(unclosed", ":| a )"])
            assertThrown!YshError(validateExpression(source));
        // Nested commands are parsed, but their failing operations never run.
        parseProgram("var words = %(literal $(exit 99)); var other = :| $[1 / 0] |");
        assertThrown!YshError(parseProgram("if (false) { var words = %(one; two) }"));
    }

    unittest {
        auto output = File.tmpfile();
        auto error = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, error);
        mem.options.set("ysh:all", true);
        executeProgram(`
            proc run-argv {
                @ARGV
                var lines = $(@ARGV | wc -l)
                printf '%s lines\n' "$lines"
                @ARGV >&2
            }
            run-argv printf '<%s>\n' 'two words' 'literal; text'
            var empty = []
            @empty printf 'empty prefix\n' && printf 'and/or\n'
        `, mem);
        assert(mem.lastStatus == 0);
        output.rewind();
        assert(output.readln() == "<two words>\n");
        assert(output.readln() == "<literal; text>\n");
        assert(output.readln() == "2 lines\n");
        assert(output.readln() == "empty prefix\n");
        assert(output.readln() == "and/or\n");
        assert(output.readln() == "");
        error.rewind();
        assert(error.readln() == "<two words>\n");
        assert(error.readln() == "<literal; text>\n");
        assert(error.readln() == "");
        parseProgram("@will_not_be_looked_up | wc -l", mem.returnMode, mem.options);
    }

    unittest {
        auto output = File.tmpfile();
        auto error = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, error);
        mem.initializeArguments("osh-d", ["printf", "unexpected output"]);
        executeProgram("@ARGV", mem);
        assert(mem.lastStatus == 127);
        output.rewind();
        assert(output.readln() == "");
        error.rewind();
        assert(error.readln() == "ysh-d: Command '@ARGV' not found (OILS-ERR-100)\n");

        mem.options.set("ysh:all", true);
        foreach (source; ["@ARGV.suffix", "@['true']suffix", "@(printf true)suffix"]) {
            assertThrown!ParseError(parseProgram(source, mem.returnMode, mem.options));
            assertThrown!ParseError(executeProgram(source, mem));
        }
    }
}
