module yshd.retained_control_test;

version (unittest) {
    import std.stdio : File;
    import std.file : getcwd, tempDir, write, readText, remove;
    import std.path : buildPath;
    import std.conv : to;
    import core.sys.posix.unistd : getpid;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory;
    import yshd.value : ValueKind, YshError;

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.initializeArguments("script", ["outer argument"]);
        executeProgram(`
            var value = 'global'
            proc lexical { assert [value === 'global'] }
            inner() { echo $value "$1"; assert [value === 'global']; }
            outer() {
                local value=local
                inner "inner argument"
                lexical
                created=global
                for word; do echo "$word"; done
                return 7
                echo unreachable
            }
            outer "one word" two
            echo returned=$?
            assert [value === 'global']
            assert [created === 'global']
            assert [ARGV === ['outer argument']]
            echo "$1"
            function named { echo alternate; }
            named
            proc proc-with-keyword-prefix { echo invoked; }
            proc-with-keyword-prefix
            read-helper() { echo read-helper; }
            read-helper
            shopt -s expand_aliases
            alias read='echo wrong'
            read-helper
            alias read-helper='echo alias-with-hyphen'
            read-helper
        `, mem);
        output.rewind();
        string actual;
        foreach (line; output.byLineCopy()) actual ~= line ~ "\n";
        assert(actual == "local inner argument\none word\ntwo\nreturned=7\nouter argument\nalternate\ninvoked\nread-helper\nread-helper\nalias-with-hyphen\n", actual);
        assert(mem.builtins.shellFunctions.contains("inner"));
        assert(mem.getCell("word") !is null); // retained assignment creates a global
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        executeProgram(`
            value=global
            read_value() { echo $value; }
            set_value() { value=changed; }
            proc creator {
                func retained() { return (value) }
                setglobal saved = retained
                assert [saved() === 'global']
            }
            outer() {
                local value=local
                creator
                read_value
                set_value
                echo $value
                shopt --unset dynamic_scope
                read_value
                value=local
                set_value
                echo $value
            }
            outer
            echo $value
            assert [saved() === 'global']
        `, mem);
        output.rewind();
        string actual;
        foreach (line; output.byLineCopy()) actual ~= line ~ "\n";
        assert(actual == "local\nchanged\nglobal\nlocal\nglobal\n", actual);
        assert(mem.options.get("dynamic_scope"));
    }

    unittest {
        foreach (source; [
            "outer() { proc inner { true }; }",
            "outer() { func inner() { return (null) }; }",
            "proc outer { inner() { true; }; }",
            "func outer() { inner() { true; }; return (null) }",
            "func undeclared() { setvar missing = 1; return (null) }",
            "proc duplicate (value) { var value = 1 }",
            "proc duplicate { var value; if (true) { var value } }",
            "proc frozen { const value = 1 }",
            "proc outer { var value = 1; proc inner { setvar value = 2 } }",
        ]) {
            bool rejected;
            try { parseProgram(source); } catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
        parseProgram("proc mutable (value; record) { setvar value = 'changed'; setvar record.key = 2 }");
        parseProgram("outer() { inner() { var value = 1; setvar value = 2; }; }");
        parseProgram("proc outer { echo $(inner() { true; }; setvar global_value = 1) }");
        parseProgram("func annotated(value Int = 1; more List[Int] = [2]) => Int { var result: Int = value + more[0]; var empty:; return (result) }");
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.initializeArguments("script", ["original"]);
        executeProgram(`
            proc observe { echo incoming=$? }
            false
            observe
            proc proc_match { assert ['abc123' ~ / <capture d+> /] }
            proc_match
            assert [_group(1) === '123']
            func func_match() { return ('abc7' ~ / <capture d+> /) }
            var matched = func_match()
            assert [matched]
            assert [_group(1) === '7']
            proc reset_args { builtin set -- from-proc }
            reset_args
            echo "$1" @ARGV
            func reset_func() { builtin set -- from-func; return (null) }
            call reset_func()
            echo "$1" @ARGV
            var visible = 'outer'
            func fail_scope() { var visible = 'inner'; error 'stop' (code=17) }
            try { call fail_scope() }
            assert [_error.code === 17]
            assert [visible === 'outer']
        `, mem);
        output.rewind();
        string actual;
        foreach (line; output.byLineCopy()) actual ~= line ~ "\n";
        assert(actual == "incoming=1\nfrom-proc original\nfrom-func original\n", actual);
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.options.set("ysh:all", true);
        auto originalDirectory = getcwd();
        executeProgram(`
            f() {
                cd / { echo inside; return; echo unreachable; }
                echo unreachable
            }
            f
            try { cd / { error 'stop' (code=17) } }
            assert [_error.code === 17]
        `, mem);
        assert(getcwd() == originalDirectory);
        assert(mem.workingDirectory == originalDirectory);
        assert(mem.get("PWD").stringValue == originalDirectory);
        auto path = buildPath(tempDir(), "grease-d-function-redirect-" ~ to!string(getpid()));
        scope (exit) remove(path);
        write(path, "before\n");
        executeProgram("deferred() { echo called; } > '" ~ path ~ "'\n", mem);
        assert(readText(path) == "before\n");
        executeProgram("deferred\n", mem);
        assert(readText(path) == "called\n");
        write(path, "before bare\n");
        executeProgram("bare_path() { echo unquoted; } > " ~ path ~ "\n", mem);
        assert(readText(path) == "before bare\n");
        executeProgram("bare_path\n", mem);
        assert(readText(path) == "unquoted\n");
        executeProgram("from_document() { cat; } <<EOF; echo defined\nargument $1\nEOF\nfrom_document later\n", mem);
        output.rewind();
        string actual;
        foreach (line; output.byLineCopy()) actual ~= line ~ "\n";
        assert(actual == "inside\ndefined\nargument later\n", actual);
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var count = 0
            while [[ $count -lt 2 ]]; do
                setvar count += 1
            done
            until [[ $count -ge 4 ]]; do setvar count += 1; done
            assert [count === 4]
            for outer in a b; do
                for inner in 1 2; do
                    if [[ $inner == 1 ]]; then continue; fi
                    echo $outer$inner
                done
            done
            for empty in; do echo unreachable; done
            for item in first second; do
                cat <<EOF
done is data
EOF
                break
            done
        `, mem);
        output.rewind();
        string actual;
        foreach (line; output.byLineCopy()) actual ~= line ~ "\n";
        assert(actual == "a2\nb2\ndone is data\n", actual);
        foreach (source; ["for item in a; do done", "while true; do", "for item in a; do echo x", "until true; do done"])
        {
            bool rejected;
            try { parseProgram(source); } catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
        bool rejected;
        try { executeProgram("stop() { break; }; for item in a b; do stop; done", mem); }
        catch (YshError error) { rejected = error.status == 1; }
        assert(rejected);
    }
}
