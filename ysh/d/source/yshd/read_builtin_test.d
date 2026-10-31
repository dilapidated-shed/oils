module yshd.read_builtin_test;

version (unittest) {
    import std.stdio : File;
    import std.conv : to;
    import yshd.read_builtin : runReadBuiltin;
    import yshd.state : Memory;
    import yshd.value : Value, ValueKind, UsageError, shellArrayValues;

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

    unittest {
        // -n honors the delimiter and splits; -N takes exact bytes and
        // does not split or interpret the line delimiter.
        auto limited = inputMemory("a b c\n");
        runReadBuiltin(["-n", "5", "first", "second", "third"], null, false, limited);
        assert(limited.lastStatus == 0);
        assert(limited.get("first").stringValue == "a");
        assert(limited.get("second").stringValue == "b");
        assert(limited.get("third").stringValue == "c");

        auto exact = inputMemory("a b c\n");
        runReadBuiltin(["-N", "5", "whole", "extra"], null, false, exact);
        assert(exact.lastStatus == 0 && exact.get("whole").stringValue == "a b c");
        assert(exact.get("extra").stringValue == "");
        runReadBuiltin(["-N", "3", "partial"], null, false, exact);
        assert(exact.lastStatus == 1 && exact.get("partial").stringValue == "\n");

        auto delim = inputMemory("abc:def");
        runReadBuiltin(["-rn5", "-d", ":", "part"], null, false, delim);
        assert(delim.lastStatus == 0 && delim.get("part").stringValue == "abc");
        runReadBuiltin(["-N3", "rest"], null, false, delim);
        assert(delim.lastStatus == 0 && delim.get("rest").stringValue == "def");
    }

    unittest {
        // -a uses an actual BashArray, and -r preserves literal backslashes.
        auto mem = inputMemory("a b c\\\\ d\n");
        runReadBuiltin(["-a", "array", "ignored"], null, false, mem);
        assert(mem.lastStatus == 0);
        assert(mem.get("array").kind == ValueKind.bashArrayValue);
        assert(shellArrayValues(mem.get("array")) == ["a", "b", "c d"]);
        auto raw = inputMemory("a b c\\\\ d\n");
        runReadBuiltin(["-ra", "array2"], null, false, raw);
        assert(shellArrayValues(raw.get("array2")) == ["a", "b", "c\\\\", "d"]);

        auto empty = inputMemory("");
        runReadBuiltin(["-a", "array"], null, false, empty);
        assert(empty.lastStatus == 1 && shellArrayValues(empty.get("array")).length == 0);
    }

    unittest {
        // The alternate fd must stay owned by Memory for the next read.
        auto mem = inputMemory("left\nright\n");
        runReadBuiltin(["-u", to!string(mem.inputFile.fileno()), "first"], null, false, mem);
        assert(mem.lastStatus == 0 && mem.get("first").stringValue == "left");
        runReadBuiltin(["-r", "second"], null, false, mem);
        assert(mem.lastStatus == 0 && mem.get("second").stringValue == "right");

        bool invalid;
        try { runReadBuiltin(["-n", "-1"], null, false, mem); }
        catch (UsageError error) { invalid = true; }
        assert(invalid);
        invalid = false;
        try { runReadBuiltin(["-u", "-3"], null, false, mem); }
        catch (UsageError error) { invalid = true; }
        assert(invalid);
    }
}
