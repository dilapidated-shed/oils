module yshd.word_array_test;

version (unittest) {
    import std.stdio : File;
    import std.exception : assertThrown;
    import yshd.state : Memory;
    import yshd.program : executeProgram, parseProgram;
    import yshd.expr : validateExpression;
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
}
