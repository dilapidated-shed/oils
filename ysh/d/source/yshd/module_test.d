module yshd.module_test;

version (unittest) {
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.stdio : File;
    import std.conv : to;
    import core.sys.posix.unistd : getpid;
    import yshd.state : Memory;
    import yshd.program : executeProgram, parseProgram;
    import yshd.module_ysh : useModule;
    import yshd.value : Value, YshError;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var x = 'global'
            proc change {
                call setVar('x', 'local')
                assert [x === 'local']
                call setVar('x', 'changed', global=true)
                assert [x === 'changed']
            }
            change
            assert [x === 'changed']
            var a = []
            var b = a
            var c = []
            assert [vm.id(a) === vm.id(b)]
            assert [vm.id(a) !== vm.id(c)]
            var mylen = __builtins__.len
            assert [mylen([1, 2, 3]) === 3]
        `, mem);
    }

    unittest {
        auto root = buildPath(tempDir(), "ysh-d-modules-" ~ to!string(getpid()));
        mkdirRecurse(root);
        scope (exit) rmdirRecurse(root);
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.declareLocal("root", Value.str(root));
        auto outer = mem.globalFrame;
        write(buildPath(root, "one.ysh"), `
            const __provide__ = :| count increment |
            var count = 1
            use $_this_dir/two.ysh
            proc increment { setglobal count += 1; echo $count }
            assert [getVar('root') === null]
            assert [two.message === 'two']
            if is-main { exit 91 }
        `);
        write(buildPath(root, "two.ysh"), `
            const __provide__ = :| message |
            use $_this_dir/one.ysh
            var message = 'two'
        `);
        assert(useModule([buildPath(root, "one.ysh")], mem) == 0);
        assert(mem.globalFrame is outer && mem.currentFrame is outer && mem.isMain);
        assert(mem.sourceDirectories.length == 0);
        executeProgram(`
            var before = one
            one increment
            assert [one.count === 1]
            use $root/one.ysh --pick increment
            assert [vm.id(before) === vm.id(one)]
            increment
            assert [getVar('count') === null]
        `, mem);
        write(buildPath(root, "bad.ysh"), "var hidden = 1\nerror 'stop' (code=17)\n");
        bool failed;
        try { useModule([buildPath(root, "bad.ysh")], mem); }
        catch (YshError error) { failed = error.status == 17; }
        assert(failed);
        assert(mem.globalFrame is outer && mem.currentFrame is outer && mem.isMain);
        assert(mem.sourceDirectories.length == 0 && mem.getCell("hidden") is null);
        // Parse-only must not try to load a module or run a source guard.
        parseProgram("use /definitely/missing; source /definitely/missing; source-guard x", mem.returnMode, mem.options);
        assert(mem.sourceGuards.length == 0);
    }
}
