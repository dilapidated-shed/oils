module yshd.read_builtin_test;

version (unittest) {
    import std.stdio : File;
    import yshd.read_builtin : runReadBuiltin;
    import yshd.state : Memory;
    import yshd.value : Value, ValueKind, UsageError;

    private Memory inputMemory(string input) {
        auto file = File.tmpfile();
        file.write(input);
        file.flush();
        file.rewind();
        return new Memory(file, File.tmpfile(), File.tmpfile());
    }

    unittest {
        auto mem = inputMemory("alpha\nbeta\r\nlast");
        runReadBuiltin(["--raw-line"], null, false, mem);
        assert(mem.lastStatus == 0 && mem.get("_reply").stringValue == "alpha");
        runReadBuiltin(["-r"], null, false, mem);
        assert(mem.lastStatus == 0 && mem.get("REPLY").stringValue == "beta\r");
        runReadBuiltin(["--raw-line", "--with-eol"], null, false, mem);
        assert(mem.lastStatus == 0 && mem.get("_reply").stringValue == "last");
        runReadBuiltin(["--raw-line"], null, false, mem);
        assert(mem.lastStatus == 1 && mem.get("_reply").stringValue == "");
    }

    unittest {
        auto mem = inputMemory("\na\nb\n\nlast");
        runReadBuiltin(["--all-lines", "--with-eol", ":lines"], null, false, mem);
        auto value = mem.get("lines");
        assert(mem.lastStatus == 0 && value.kind == ValueKind.list);
        assert(value.listValue.items.length == 5);
        assert(value.listValue.items[0].stringValue == "\n");
        assert(value.listValue.items[1].stringValue == "a\n");
        assert(value.listValue.items[3].stringValue == "\n");
        assert(value.listValue.items[4].stringValue == "last");
        auto empty = inputMemory("");
        runReadBuiltin(["--all-lines"], null, false, empty);
        assert(empty.get("_reply").listValue.items.length == 0);
        auto noEol = inputMemory("a\nb\n");
        runReadBuiltin(["--all-lines"], null, false, noEol);
        auto lines = noEol.get("_reply").listValue.items;
        assert(lines.length == 2 && lines[0].stringValue == "a" && lines[1].stringValue == "b");
    }

    unittest {
        auto mem = inputMemory("a\\b c  \0next\0tail");
        mem.setShellVar("IFS", Value.str(" "));
        runReadBuiltin(["-0", "first"], null, false, mem);
        assert(mem.lastStatus == 0 && mem.get("first").stringValue == "a\\b c  ");
        runReadBuiltin(["-r", "-d", "", "second"], null, false, mem);
        assert(mem.lastStatus == 0 && mem.get("second").stringValue == "next");
        runReadBuiltin(["-0"], null, false, mem);
        assert(mem.lastStatus == 1 && mem.get("REPLY").stringValue == "tail");
    }

    unittest {
        auto mem = inputMemory("one two  three\n\\a\\ b\n");
        runReadBuiltin(["-r", "first", "second"], null, false, mem);
        assert(mem.lastStatus == 0 && mem.get("first").stringValue == "one");
        assert(mem.get("second").stringValue == "two  three");
        runReadBuiltin(["-r"], null, false, mem);
        assert(mem.get("REPLY").stringValue == "\\a\\ b");
    }

    unittest {
        auto mem = inputMemory("foo\0bar");
        runReadBuiltin(["--num-bytes", "4"], null, false, mem);
        assert(mem.get("_reply").stringValue == "foo\0" && mem.lastStatus == 0);
        runReadBuiltin(["--all"], null, false, mem);
        assert(mem.get("_reply").stringValue == "bar" && mem.lastStatus == 0);
        bool rejected;
        try { runReadBuiltin(["--raw-line", "extraneous"], null, false, mem); }
        catch (UsageError error) { rejected = true; }
        assert(rejected);
    }
}
