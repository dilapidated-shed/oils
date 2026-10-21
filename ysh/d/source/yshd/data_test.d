module yshd.data_test;

version (unittest) {
    import std.stdio : File;
    import yshd.io_ysh : encodeDataValue, encodeJ8String, encodeBString,
        WriteEncoding, DataEncodeError;
    import yshd.pretty : prettyValue;
    import yshd.value : Value, YshDict, YshError;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory;

    unittest {
        auto reusedValue = Value.list([Value.integer(1), Value.integer(2)]);
        auto dict = new YshDict();
        dict.set("left", reusedValue);
        dict.set("right", reusedValue);
        assert(encodeDataValue(Value.dictRef(dict)) == `{"left":[1,2],"right":[1,2]}`);
        assert(encodeDataValue(Value.list([Value.dict(), reusedValue]), WriteEncoding.json, 2) ==
            "[\n  {},\n  [\n    1,\n    2\n  ]\n]");
        reusedValue.listValue.items[0] = reusedValue;
        bool rejected;
        try { encodeDataValue(reusedValue); } catch (DataEncodeError error) { rejected = true; }
        assert(rejected);
        assert(encodeDataValue(reusedValue, WriteEncoding.j8, -1, false, true) == "[[...],2]");
        assert(prettyValue(reusedValue) == "(List)  [[...], 2]");
        assert(encodeDataValue(Value.range(1, 5), WriteEncoding.json, 2, false) == "null");
        assert(encodeDataValue(Value.floating(double.infinity)) == "null");
        assert(encodeDataValue(Value.floating(double.nan), WriteEncoding.j8) == "NAN");
        assert(encodeJ8String("μ\xff") == "b'μ\\yff'");
        assert(encodeBString("\x01\n") == "b'\\u{1}\\n'");
        assert(prettyValue(Value.str("a\\b")) == "(Str)   b'a\\\\b'");
        assert(prettyValue(Value.str("can't")) == "(Str)   b'can\\'t'");
        assert(prettyValue(Value.floating(-0.0)) == "(Float) -0.0");
        assert(prettyValue(Value.range(1, 100)) == "(Range 1 ..< 100)");
    }

    unittest {
        auto dict = new YshDict();
        dict.set("long key", Value.list([Value.integer(1), Value.integer(2)]));
        assert(prettyValue(Value.dictRef(dict)) == "(Dict)  {'long key': [1, 2]}");
        assert(prettyValue(Value.dictRef(dict), 18) ==
            "(Dict)\n{\n    'long key': [\n        1, 2\n    ]\n}");
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        executeProgram(`
            var x = {a: [1, 2]}
            json write (x, space=0)
            json8 write (x, space=4)
            pp value ('text')
            = null
            assert [toJson(x) === '{"a":[1,2]}']
            assert [toJson(INFINITY) === 'null']
            assert [toJson8(INFINITY) === 'INFINITY']
            var cycle = []
            call cycle->append(cycle)
            try { call toJson(cycle) }
            assert [_error.code === 4]
            json write (cycle)
        `, mem);
        assert(mem.lastStatus == 1);
        output.rewind();
        string actual;
        while (!output.eof()) actual ~= output.readln();
        assert(actual == "{\"a\":[1,2]}\n{\n    \"a\": [\n        1,\n        2\n    ]\n}\n" ~
            "(Str)   'text'\n(Null)  null\n", actual);
        parseProgram("json write (); pp value (); json write (undefined(), space=bad)");
    }
}
