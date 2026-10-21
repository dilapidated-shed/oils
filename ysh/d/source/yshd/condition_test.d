module yshd.condition_test;

version (unittest) {
    import std.stdio : File;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory;
    import yshd.value : YshError;

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        executeProgram(`
            var text = 'abc123'
            [[ $text =~ ([[:alpha:]]+)([[:digit:]]+) ]]
            assert [_group(1) === 'abc']
            assert [_group(2) === '123']
            var previous = _group(0)
            [[ yes || $undefined ]]
            [[ '' && $undefined ]]
            [[ ! -n '' && ( 'name.cc' == *.cc || '' ) ]]
            [[ 'name.cc' != '*.cc' ]]
            assert [_group(0) === previous]
            [[ '(' =~ '(' ]]
            [[ x =~ + ]]
        `, mem);
        assert(mem.lastStatus == 2);
        executeProgram(`
            [[ 3 -gt 2 ]] && echo greater
            [[ x == y ]] || echo unequal
            if [[ $text =~ [[:digit:]]+ ]] { echo matched }
            [[ -d / ]]
            [[ -z '' ]]
        `, mem);
        assert(mem.lastStatus == 0);
        output.rewind();
        assert(output.readln() == "greater\n");
        assert(output.readln() == "unequal\n");
        assert(output.readln() == "matched\n");
        parseProgram("[[ yes || $[missing()] ]]");
        bool rejected;
        try { parseProgram("[[ yes || ]]"); } catch (YshError error) { rejected = error.status == 2; }
        assert(rejected);
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        executeProgram(`
            if false; then echo bad
            elif true; then echo legacy
            else echo bad
            fi
            if true
            then
              if false; then echo bad; else echo nested; fi
            fi
            if true; then echo piped; fi | cat
            if true { echo braces }
            if false; then echo bad; fi
        `, mem);
        assert(mem.lastStatus == 0);
        output.rewind();
        assert(output.readln() == "legacy\n");
        assert(output.readln() == "nested\n");
        assert(output.readln() == "piped\n");
        assert(output.readln() == "braces\n");
        output.seek(0, 2);
        auto documentStart = output.tell();
        executeProgram("if true; then cat <<EOF\nfi is data\nEOF\nfi\n", mem);
        output.seek(documentStart);
        assert(output.readln() == "fi is data\n");
        foreach (source; ["if false; then var bad = (1 +); fi", "if true; then fi", "if true; then :; else fi", "if ; then :; fi"])
        {
            bool rejected;
            try { parseProgram(source); } catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
    }

    unittest {
        string nested;
        foreach (i; 0 .. 20) nested ~= "if (true) {\n";
        nested ~= "echo deepest\n";
        foreach (i; 0 .. 20) nested ~= "}\n";
        parseProgram(nested);
    }
}
