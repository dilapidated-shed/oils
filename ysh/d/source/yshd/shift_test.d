module yshd.shift_test;

version (unittest) {
    import core.sys.posix.unistd : getpid;
    import std.bigint : BigInt;
    import std.conv : to;
    import std.file : mkdir, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.stdio : File;
    import std.string : indexOf;
    import yshd.eval_scope : EvalOptions, withEvalBindings;
    import yshd.expr : evaluate;
    import yshd.program : executeProgram;
    import yshd.shift : runShift;
    import yshd.state : Memory, ShellArgumentFrame;
    import yshd.value : FatalRuntimeError, UsageError, Value, YshError;

    private Memory memory() {
        return new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string result, line;
        while ((line = file.readln()).length) result ~= line;
        return result;
    }

    private void run(string source, Memory mem) {
        try { executeProgram(source, mem); }
        catch (YshError error) {
            assert(false, "shift test source:\n" ~ source ~ "\nfailed with: " ~ error.msg);
        }
    }

    unittest {
        auto mem = memory();
        mem.initializeArguments("original-zero", ["a", "b", "c"]);
        auto original = mem.shellArgumentFrame;
        assert(runShift([], mem) == 0 && mem.shellArguments == ["b", "c"]);
        assert(runShift(["1"], mem) == 0 && mem.shellArguments == ["c"]);
        assert(runShift(["-1"], mem) == 0 && mem.shellArguments == ["b", "c"]);
        assert(runShift(["-2"], mem) == 0 && mem.shellArguments == ["c"]);
        assert(mem.shellArgumentCount() == 4);
        assert(mem.shellArgument(1) == "c" && mem.shellArgument(2) == "a" &&
            mem.shellArgument(3) == "b" && mem.shellArgument(4) == "c");
        assert(!mem.shellArgumentDefined(5) && mem.shellArgument(5) == "");
        assert(mem.simpleShellVariable('#') == "4");
        assert(mem.shellArgument(0) == "original-zero");
        assert(mem.get("ARGV").listValue.length == 3 &&
            mem.get("ARGV").listValue.items[0].stringValue == "a");
        assert(runShift(["99999999999999999999999999999999999999999999999999"], mem) == 1);
        assert(mem.shellArgumentFrame is original && mem.shellArgumentCount() == 4 &&
            mem.shellArguments == ["c"], "failed shift mutated the positional frame");
        assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "");
    }

    unittest {
        auto mem = memory();
        mem.initializeArguments("zero", ["a", "b", "c"]);
        enum huge = "99999999999999999999999999999999999999999999999999";
        assert(runShift(["-" ~ huge], mem) == 0);
        assert(mem.shellArgumentCount() == BigInt(huge) + 3);
        assert(mem.shellArguments == ["a", "b", "c"], "negative Python slice did not clamp");
        bool failed;
        try { mem.shellArgument(1); }
        catch (FatalRuntimeError error) { failed = error.status == 1; }
        assert(failed, "out-of-range retained negative index lost its fatal boundary");
        assert(runShift([huge], mem) == 0 && mem.shellArguments == ["a", "b", "c"]);
        assert(mem.shellArgumentCount() == 3);
        assert(runShift(["010"], mem) == 1, "leading zero was interpreted as octal");
        assert(runShift([" +002 \t"], mem) == 0 && mem.shellArguments == ["c"]);
        assert(runShift(["-0"], mem) == 0 && mem.shellArgumentCount() == 1);

        auto view = mem.shellArguments;
        view[0] = "changed";
        assert(mem.shellArgument(1) == "c", "visible argv escaped as mutable raw storage");
        mem.shellArguments = ["reset", "words"];
        assert(mem.shellArgumentCount() == 2 && mem.shellArgument(1) == "reset");
        assert(mem.get("ARGV").listValue.length == 3 && mem.get("ARGV").listValue.items[0].stringValue == "a");
    }

    unittest {
        auto mem = memory();
        run("set -- 1 2 3 4; shift; echo \"$@\"; shift 2; echo \"$@\"", mem);
        assert(mem.lastStatus == 0 && contents(mem.outputFile) == "2 3 4\n4\n");
        assert(contents(mem.errorFile) == "");

        mem = memory();
        run("set -- one; shift 2", mem);
        assert(mem.lastStatus == 1 && mem.shellArguments == ["one"]);
        assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "",
            "shifting too far must be a silent status1");
        run("shift 0", mem);
        assert(mem.lastStatus == 0 && mem.shellArguments == ["one"]);
        run("shift; shift", mem);
        assert(mem.lastStatus == 1 && mem.shellArguments.length == 0);

        foreach (source; ["shift ZZZ", "shift ''", "shift ' '", "shift --", "shift --help",
                "shift 0x2", "shift 0o2", "shift 1_0", "shift 2.0", "shift '１２'", "shift '٠٢'", "shift 1 extra"]) {
            mem = memory();
            mem.shellArguments = ["a", "b", "c"];
            run(source, mem);
            assert(mem.lastStatus == 2 && mem.shellArguments == ["a", "b", "c"], source);
            assert(contents(mem.outputFile) == "" && contents(mem.errorFile).length, source);
        }
    }

    unittest {
        auto mem = memory();
        mem.initializeArguments("kept-zero", ["a", "b", "c"]);
        run(`
            shift -1
            echo "$#:$1:$2:$3:$4:${5-default}"
            echo "$@"
            IFS=:
            echo "$*"
            for item; do echo "[$item]"; done
            shift 2
            echo "$#:$1:$2:${3-default}:$0"
        `, mem);
        assert(contents(mem.outputFile) == "4:c:a:b:c:default\nc\nc\n[c]\n2:b:c:default:kept-zero\n");
        assert(contents(mem.errorFile) == "");
        run("shift 999 >&- 2>&-", mem);
        assert(mem.lastStatus == 1 && mem.shellArguments == ["b", "c"]);
        run("shift 0 >&- 2>&-", mem);
        assert(mem.lastStatus == 0, "shift attempted report output");
    }

    private uint directoryIndex;
    private string directory() {
        auto path = buildPath(tempDir(), "ysh-d-shift-" ~ to!string(getpid()) ~ "-" ~ to!string(directoryIndex++));
        mkdir(path);
        return path;
    }

    unittest {
        auto base = directory();
        scope (exit) rmdirRecurse(base);
        auto source = buildPath(base, "arguments.grease");
        write(source, "shift -1\n");
        auto mem = memory();
        mem.initializeArguments("zero", ["a", "b", "c"]);
        run("shift 2; f() { shift; set -- replacement; }; f x y", mem);
        assert(mem.shellArguments == ["c"] && mem.shellArgumentCount() == 1);
        run("shift -1", mem);
        assert(mem.shellArguments == ["b", "c"], "shell function lost caller's consumed words");
        run("source '" ~ source ~ "' child words", mem);
        assert(mem.shellArguments == ["b", "c"] && mem.shellArgumentCount() == 2);
        run("source '" ~ source ~ "'", mem);
        assert(mem.shellArguments == ["a", "b", "c"]);
        write(source, "set -- shared reset\n");
        run("source '" ~ source ~ "'", mem);
        assert(mem.shellArguments == ["shared", "reset"], "source without words hid set -- changes");
        run("shift; source '" ~ source ~ "' temporary", mem);
        assert(mem.shellArguments == ["reset"]);
        run("shift -1", mem);
        assert(mem.shellArguments == ["shared", "reset"], "source with words lost caller's cursor");
        assert(mem.argumentZero == "zero" && contents(mem.errorFile) == "");
    }

    unittest {
        auto mem = memory();
        mem.initializeArguments("zero", ["global", "tail"]);
        mem.options.set("ysh:all", true);
        run(`
            proc consume {
                shift
                assert [ARGV === ['local']]
            }
            consume local
            assert [ARGV === ['global', 'tail']]
        `, mem);
        assert(mem.shellArguments == ["tail"], "YSH proc incorrectly pushed a shell argv frame");
        auto outer = mem.shellArgumentFrame;
        EvalOptions options;
        options.changeArguments = true;
        options.arguments = ["temporary", "args"];
        withEvalBindings(mem, options, {
            assert(runShift(["-1"], mem) == 0);
            assert(mem.shellArguments == ["args"] && mem.shellArgumentCount() == 3);
            mem.shellArguments = ["temporary-reset"];
            return Value.nullValue();
        });
        assert(mem.shellArgumentFrame is outer && mem.shellArguments == ["tail"]);
        withEvalBindings(mem, EvalOptions.init, {
            assert(runShift(["-1"], mem) == 0);
            return Value.nullValue();
        });
        assert(mem.shellArguments == ["global", "tail"], "eval without pos_args restored caller shift");
        assert(contents(mem.errorFile) == "");
    }

    unittest {
        auto mem = memory();
        mem.options.set("ysh:all", true);
        run(`
            builtin set -- a b c d e f g h
            var calls = 0
            func argument() { setglobal calls += 1; return (42) }
            shift 0 (argument(); named=argument()) { error 'block ran' }
            assert [calls === 2]
            builtin shift 0 (argument())
            command shift 0 (; named=argument())
            assert [calls === 4]
            shift 0 [unbound]
            shift 0 [argument()]
            assert [calls === 4]
            shift 0 { error 'block ran' }
            shift 0 (;; ^(error 'block ran'))
            shift
            builtin shift
            command shift
            var name = 'shift'
            $name
        `, mem);
        assert(mem.lastStatus == 0 && mem.shellArguments == ["e", "f", "g", "h"]);
        assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "");
        foreach (source; ["shift (unbound)", "shift (; named=unbound)"]) {
            bool failed;
            try { executeProgram(source, mem); }
            catch (FatalRuntimeError error) { failed = error.status == 1; }
            assert(failed && mem.shellArguments == ["e", "f", "g", "h"], source);
        }
    }

    unittest {
        auto mem = memory();
        run(`
            set -- a b c d e
            shift() { echo wrong; }
            shift
            builtin shift
            command shift
            name=shift
            $name
        `, mem);
        assert(mem.lastStatus == 0 && mem.shellArguments == ["e"]);
        assert(contents(mem.outputFile) == "" && contents(mem.errorFile) == "",
            "a shell function shadowed the special shift builtin");
    }

    unittest {
        auto mem = memory();
        mem.options.set("ysh:all", true);
        mem.shellArguments = ["a", "b", "c"];
        run("shift 2; func replacement() { shift -1; return ('x') }", mem);
        assert(evaluate(`'a'.replace('a', ^[replacement()])`, mem).stringValue == "x");
        assert(mem.shellArguments == ["b", "c"], "plain string replacement lost shared positional mutation");
        auto outer = mem.shellArgumentFrame;
        assert(evaluate(`'a'.replace(/ <capture dot as part> /, ^[replacement()])`, mem).stringValue == "x");
        assert(mem.shellArgumentFrame is outer && mem.shellArguments == ["b", "c"],
            "regex replacement lost caller's complete positional frame");
    }
}
