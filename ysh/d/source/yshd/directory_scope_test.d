module yshd.directory_scope_test;

version (unittest) {
    import std.array : array;
    import std.conv : to;
    import std.file : chdir, getcwd, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.stdio : File;
    import std.string : replace;
    import core.sys.posix.unistd : getpid, symlink;
    import std.string : toStringz;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : Value;
    import yshd.dirs : runDirectoryBuiltin;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.initializeArguments("special-parameters", []);
        executeProgram(`
            assert [$0 === 'special-parameters']
            set -- one two
            assert [$# === '2']
            assert [$1 === 'one']
            assert [$2 === 'two']
            assert [$$ === "$$"]
            assert [$- === 'eu']
            var before = $$
            var isolated = io.captureStdout(^(echo $$))
            assert [isolated === before]
            shopt --unset strict_array {
                var IFS = ':'
                assert [$* === 'one two']
                assert ["$*" === 'one:two']
                assert [$@ === 'one two']
                assert ["$@" === 'one two']
            }
        `, mem);
        import yshd.program : parseProgram;
        import yshd.value : YshError;
        foreach (source; ["var x = $name", "var x = $10"]) {
            bool rejected;
            try { parseProgram(source, mem.returnMode, mem.options); }
            catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
        foreach (source; ["try { var words = $@ }", "try { var pid = $! }"]) {
            bool failed;
            try { executeProgram(source, mem); }
            catch (YshError error) { failed = error.status == 1; }
            assert(failed, source);
        }
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var original = 'outer'
            shvar IFS=: original=temporary absent=value {
                assert [original === 'temporary']
                assert [split('a:b') === ['a', 'b']]
                var created = 'retained'
                shell_created=retained
            }
            assert [original === 'outer']
            assert [created === 'retained']
            assert [shell_created === 'retained']
            assert [getVar('absent') === null]
            try { shvar original=temporary { error 'stop' (code=17) } }
            assert [_error.code === 17]
            assert [original === 'outer']
            proc early {
                shvar original=temporary { return 0 }
            }
            early
            assert [original === 'outer']
            shvar -- original=one original=two { assert [original === 'two'] }
            assert [original === 'outer']
            shopt --unset errexit {
                shvar original=temporary { false }
                assert [$? === '0']
                shvar bad { echo unreachable }
                assert [$? === '2']
            }
            var command = ^(assert [original === 'temporary'])
            shvar original=temporary (; ; command)
            assert [original === 'outer']
        `, mem);
    }

    unittest {
        auto initial = getcwd();
        scope (exit) chdir(initial);
        auto base = buildPath(tempDir(), "grease-d-dirs-" ~ to!string(getpid()));
        mkdirRecurse(buildPath(base, "real", "child"));
        scope (exit) { chdir(initial); rmdirRecurse(base); }
        auto link = buildPath(base, "link");
        assert(symlink(buildPath(base, "real", "child").toStringz(), link.toStringz()) == 0);
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.declareLocal("target", Value.str(base));
        mem.declareLocal("initial", Value.str(initial));
        mem.declareLocal("HOME", Value.str(base));
        executeProgram(`
            pushd $target
            assert [PWD === target]
            pushd ./real
            assert [PWD === target ++ '/real']
            dirs -pv
            popd
            assert [PWD === target]
            cd real
            assert [PWD === target ++ '/real']
            popd
            assert [PWD === initial]
            cd $target {
                pushd /
            }
            assert [PWD === target]
            popd
            assert [PWD === initial]
            cd $target/link/.. { assert [PWD === target] }
            cd -P $target/link/.. { assert [PWD === target ++ '/real'] }
            assert [PWD === initial]
            try { cd $target { dirs -c } }
            assert [_error.code === 1]
        `, mem);
        assert(mem.lastStatus == 0); // cleared stack cannot restore the cd block
        assert(getcwd() == base);
        assert(mem.workingDirectory == base);
        assert(mem.directoryStack.entries() == [base]);
        output.rewind();
        auto text = output.byLineCopy().array;
        // -v has priority over -p, and HOME substitution is a path boundary.
        assert(text[0] == "~ " ~ initial);
        assert(text[1] == "~/real ~ " ~ initial);
        assert(text[2] == " 0  ~/real");
        assert(text[3] == " 1  ~");
        assert(text[4] == " 2  " ~ initial);
        assert(runDirectoryBuiltin("dirs", ["-cl"], mem) == 0);
        assert(runDirectoryBuiltin("popd", [], mem) == 1);
    }
}
