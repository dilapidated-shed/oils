module yshd.invocation_order_test;

version (unittest) {
    import core.sys.posix.unistd : getpid;
    import std.conv : to;
    import std.file : exists, mkdir, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.stdio : File;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : Value;

    private Memory memory(string text = "") {
        auto input = File.tmpfile();
        input.write(text);
        input.flush();
        input.rewind();
        auto mem = new Memory(input, File.tmpfile(), File.tmpfile());
        mem.initializeArguments("invocation-order", []);
        return mem;
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string result, line;
        while ((line = file.readln()).length) result ~= line;
        return result;
    }

    private string directory() {
        static size_t sequence;
        auto path = buildPath(tempDir(), "ysh-d-invocation-order-" ~
            to!string(getpid()) ~ "-" ~ to!string(sequence++));
        assert(!exists(path), "invocation test directory already exists");
        mkdir(path);
        return path;
    }

    // These command sources and outcomes are checked against the actual
    // retained interpreter in the original sh_spec harness. They exercise
    // the common invocation boundary rather than GetOpts' parsing algorithm.
    unittest {
        auto mem = memory();
        executeProgram(`
            shopt --set ysh:upgrade
            set -- a b c
            func eager() { echo "eager=${BOUND-unbound}"; return (42) }
            BOUND=temporary shift (eager())
            echo "$?:$#:$1"
        `, mem);
        assert(contents(mem.outputFile) == "eager=unbound\n0:2:b\n",
            "temporary environment was visible during eager argument evaluation");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        auto mem = memory();
        executeProgram(`
            shopt --set ysh:upgrade
            var calls = 0
            func eager() { setglobal calls += 1; return (42) }
            proc p (; value) { echo "proc=$value" }
            set -- a b c
            builtin shift (eager())
            command shift (eager())
            p (eager())
            echo "$calls:$#:$1"
        `, mem);
        assert(contents(mem.outputFile) == "proc=42\n3:1:c\n",
            "a prefix or proc evaluated its typed packet more than once");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        auto mem = memory();
        executeProgram(`
            shopt --set ysh:upgrade
            var line = ''
            var calls = 0
            func place(p) { setglobal calls += 1; echo eager; return (p) }
            read --all <<< text (place(&line))
            printf '%s:%s' "$calls" "$line"
        `, mem);
        assert(contents(mem.outputFile) == "eager\n1:text\n",
            "read lost the prepared Place or evaluated it more than once");
        assert(mem.get("line").stringValue == "text\n");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        auto mem = memory();
        executeProgram(`
            shopt --set ysh:upgrade
            var calls = 0
            func eager() { setglobal calls += 1; return (42) }
            set -- a b c
            shift [eager()]
            shift { echo unexpected-block }
            echo "$calls:$#:$1"
        `, mem);
        assert(contents(mem.outputFile) == "0:1:c\n",
            "preparation evaluated a lazy value or executed a literal block");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto mem = memory();
        mem.setGlobal("directory", Value.str(path));
        executeProgram(`
            shopt --set ysh:upgrade
            set -- a b
            func eager() { echo eager; return (42) }
            { shift (eager()); echo inside } > "$directory/out"
            echo outside
        `, mem);
        assert(contents(mem.outputFile) == "outside\n",
            "compound-body argument evaluation escaped its outer redirect");
        assert(readText(buildPath(path, "out")) == "eager\ninside\n");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto mem = memory();
        mem.setGlobal("directory", Value.str(path));
        executeProgram(`
            shopt --set ysh:upgrade
            shopt --set expand_aliases
            set -- a b
            alias G='shift'
            G > "$directory/out"
            echo "$?:$#:$1"
        `, mem);
        assert(contents(mem.outputFile) == "0:1:b\n",
            "ordinary alias expansion was lost at the preparation boundary");
        assert(readText(buildPath(path, "out")) == "");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto mem = memory();
        mem.setGlobal("directory", Value.str(path));
        executeProgram(`
            shopt --set ysh:upgrade
            json write (42) > "$directory/json"
            pp test_ ('ok') > "$directory/pp"
        `, mem);
        assert(contents(mem.outputFile) == "");
        assert(readText(buildPath(path, "json")) == "42\n");
        assert(readText(buildPath(path, "pp")) == "(Str)   \"ok\"\n");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto mem = memory();
        mem.setGlobal("directory", Value.str(path));
        executeProgram(`
            shopt --set ysh:upgrade
            set -- a b
            var target = "$directory/before"
            func eager() {
                setglobal target = "$directory/after"
                echo eager
                return (42)
            }
            shift > "$target" (eager())
            echo "$?:$#:$1"
        `, mem);
        assert(contents(mem.outputFile) == "eager\n0:1:b\n",
            "eager output entered its command's redirect");
        assert(!exists(buildPath(path, "before")),
            "redirect operand expanded before its eager typed argument");
        assert(readText(buildPath(path, "after")) == "");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        auto path = directory();
        scope (exit) rmdirRecurse(path);
        auto mem = memory();
        mem.setGlobal("directory", Value.str(path));
        executeProgram(`
            shopt --set ysh:upgrade
            set -- a b
            try { shift > "$directory/unexpected" (1 / 0) }
            echo "$[_error.code]:$#:$1"
        `, mem);
        assert(contents(mem.outputFile) == "3:2:a\n");
        assert(!exists(buildPath(path, "unexpected")),
            "eager argument failure still created its redirect file");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }

    unittest {
        struct Case { string source; string output; }
        foreach (item; [
            Case(`OPTIND=2 getopts ab opt -a -b
                echo "$?:$opt:$OPTIND:$OPTARG"`, "0:b:1:\n"),
            Case(`OPTERR=0 getopts a opt -Z
                echo "$?:$opt:$OPTIND:$OPTARG:${OPTERR-undefined}"`, "0:?:2::undefined\n"),
            Case(`opt=seed getopts a opt -a
                echo "$?:${opt-undefined}:$OPTIND:$OPTARG"`, "0:undefined:2:\n"),
            Case(`OPTARG=seed getopts a: opt -a value
                echo "$?:$opt:$OPTIND:${OPTARG-undefined}"`, "0:a:3:undefined\n"),
            Case(`opt=outside
                OPTARG=outside
                opt=seed OPTARG=seed getopts a: opt -a value
                echo "$?:$opt:$OPTIND:$OPTARG"`, "0:outside:3:outside\n")]) {
            auto mem = memory();
            executeProgram(item.source, mem);
            assert(contents(mem.outputFile) == item.output,
                "OSH prefix cells were not scoped to dispatch: " ~ item.source);
            assert(mem.lastStatus == 0 && contents(mem.errorFile) == "", item.source);
        }
    }

    unittest {
        auto mem = memory();
        executeProgram(`
            shopt --set ysh:upgrade
            var value = 'before'
            func eager() { setglobal value = 'after'; echo eager; return (42) }
            proc p (; ignored) { echo "BOUND=$[ENV.BOUND]" }
            BOUND=$value p (eager())
            echo "value=$value"
        `, mem);
        assert(contents(mem.outputFile) == "eager\nBOUND=after\nvalue=after\n",
            "prefix assignment RHS expanded before eager typed arguments");
        assert(mem.lastStatus == 0 && contents(mem.errorFile) == "");
    }
}
