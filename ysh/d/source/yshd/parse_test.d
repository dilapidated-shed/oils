module yshd.parse_test;

version (unittest) {
    import std.file : getcwd;
    import std.stdio : File;
    import std.conv : to;
    import yshd.program : parseProgram, executeProgram, ShellExit;
    import yshd.state : Memory;
    import yshd.value : YshError;

    private void rejects(string source) {
        bool rejected;
        try { parseProgram(source); }
        catch (YshError error) { rejected = true; }
        assert(rejected, "accepted invalid source: " ~ source);
    }

    unittest {
        // Unbound names, failed commands and runtime errors must not be
        // evaluated. Both arms and bodies of uncalled functions still parse.
        parseProgram(`
            var x = undefined(1 / 0)
            setvar missing.field[unknown()] = x
            func unused(a=missing()) { return (a + x) }
            proc never { exit 91; source /no/such/file }
            if (unknown()) { false } else { exit 92 }
            while (true) { continue }
            while no_such_command { break }
            for x in (missing()) { echo $x }
            for x in $missing @unknown { echo $x }
            echo "$missing $[missing()] $(no_such_command) ${unknown%/*}"
            write @unknown @[missing()] @(no_such_command)
            var sub = $(no_such_command)
            var quoted = "$(no_such_command) $[unknown()]"
            var words = :| a $[unknown()] $(no_such_command) |
            var empty = :||
            echo "${missing:-$(no_such_command)}"
            true && no_such_command || exit 93
            false ∧ no_such_command ∨ ¬ true
            source /no/such/file
            eval 'var invalid = '
            exit not-a-number
        `);
        rejects("var x = 1 +");
        rejects("setvar 42 = 1");
        rejects("if (false) { var x = 1 + }");
        rejects("if (true) { true } else { var x = [1, }");
        rejects("func unused(a=1 +) { return (a) }");
        rejects("proc unused { echo $[1 +] }");
        rejects("while (false) { var x = }");
        rejects("for x in ([]) { var y = }");
        rejects("echo $(if (false) { var x = })");
        rejects("var x = $(echo $[1 +])");
        rejects("var x = \"$[1 +]\"");
        rejects("var x = :| $[1 +] |");
        rejects("echo ${x:-$[1 +]}");
        rejects("echo \"$(echo $[1 +])\"");
        rejects("true || var x = 1 +");
        rejects("true &&");
        rejects("echo a | | echo b");
        rejects("echo >");
        rejects("echo 'unterminated");
        rejects("if (true) { echo yes");
        rejects("func wrong() { return 42 }");
        rejects("proc wrong { return (42) }");
        rejects("func wrong() { return (1, 2) }");
    }

    version (linux) unittest {
        auto sentinel = File.tmpfile();
        sentinel.write("preserved\n");
        sentinel.flush();
        auto path = "/proc/self/fd/" ~ to!string(sentinel.fileno());
        auto originalDirectory = getcwd();
        parseProgram("echo changed > " ~ path ~ "; true > " ~ path ~
            "; echo $(echo substitution > " ~ path ~ "); cd /; exit 94");
        sentinel.rewind();
        assert(sentinel.readln() == "preserved\n");
        assert(sentinel.readln().length == 0);
        assert(getcwd() == originalDirectory);
        // Opening either redirect here would fail. Neither is opened by -n.
        parseProgram("echo x > /no/such/directory/file; cat < /no/such/file");
    }

    version (linux) unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        foreach (source; ["false", "return 7", ""]) {
            auto script = File.tmpfile();
            script.write(source);
            script.flush();
            auto path = "/proc/self/fd/" ~ to!string(script.fileno());
            mem.lastStatus = 42;
            executeProgram("source '" ~ path ~ "'", mem);
            assert(mem.lastStatus == (source == "false" ? 1 : source.length ? 7 : 0));
        }
        auto exits = File.tmpfile();
        exits.write("exit 23");
        exits.flush();
        bool exited;
        try { executeProgram("source '/proc/self/fd/" ~ to!string(exits.fileno()) ~ "'", mem); }
        catch (ShellExit control) { exited = control.status == 23; }
        assert(exited);
        executeProgram("eval 'false'", mem);
        assert(mem.lastStatus == 1);
        executeProgram("eval ''", mem);
        assert(mem.lastStatus == 0);
        mem.lastStatus = 42;
        executeProgram("eval 'echo status=$?'", mem);
        output.rewind();
        assert(output.readln() == "status=42\n");
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        executeProgram(`
            set -e
            false && echo wrong
            true || echo wrong
            false || echo recovered
            true && echo selected
            false ∧ echo wrong ∨ echo unicode
            true && ! true
            var x = 0
            proc again { setglobal x = x + 1; if (x < 3) { true } else { false } }
            while again { echo $x }
            echo done
        `, mem);
        assert(mem.lastStatus == 0);
        output.rewind();
        string actual;
        while (!output.eof()) actual ~= output.readln();
        assert(actual == "recovered\nselected\nunicode\n1\n2\ndone\n", actual);
        bool exited;
        try { executeProgram("true && false; echo wrong", mem); }
        catch (ShellExit control) { exited = control.status == 1; }
        assert(exited);
        mem.errexit = false;
        executeProgram("var once = 0; while (once < 1) { setvar once += 1; false }", mem);
        assert(mem.lastStatus == 1);
        executeProgram("while false { echo wrong }", mem);
        assert(mem.lastStatus == 0);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        executeProgram(`
            var a = [8, 16]
            var calls = 0
            func index() { setglobal calls += 1; return (0) }
            setvar a[index()] //= 3
            assert [calls === 1]
            assert [a[0] === 2]
            var empty = :||
            var words = :| a 'b c' |
            assert [len(empty) === 0]
            assert [words[1] === 'b c']
            assert [0b1111_0000 === 240]
            assert [0o1755 === 1005]
            assert [0xffff === 65535]
            assert ['  TRUE ' ~== true]
            assert ['  4_2 ' ~== 42]
            set -u
            echo ${missing:-'default value'}
            var value = 'present'
            echo ${value:-$(setglobal calls = 99)}
            assert [calls === 1]
            echo ${assigned:=fallback}
            assert [assigned === 'fallback']
        `, mem);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        executeProgram(`
            func first(x) { return ('before') }
            func second(x) { return ('after') }
            func rebind() { setglobal first = second; return (null) }
            assert [first(rebind()) === 'before']
            assert [first(null) === 'after']
            proc status { return 42 }
            status
            assert [42 === 42]
            try { false; setglobal unreachable = true }
            assert [_error.code === 1]
            proc caught { try { error 'details' (code=99) } }
            caught
            assert [_error.code === 99]
        `, mem);
        assert(mem.getCell("unreachable") is null);
        assert(!mem.errexit && !mem.options.get("command_sub_errexit"));
    }
}
