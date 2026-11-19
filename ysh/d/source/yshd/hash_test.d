module yshd.hash_test;

version (unittest) {
    import core.sys.posix.sys.stat : chmod, mkfifo;
    import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
    import core.sys.posix.unistd : symlink, fork, _exit, getpid;
    import std.conv : to;
    import std.file : mkdirRecurse, rmdirRecurse, remove, tempDir, write, chdir, getcwd;
    import std.path : buildPath;
    import std.stdio : File;
    import std.string : toStringz;
    import yshd.command_lookup : lookupExecutable;
    import yshd.hash : runHash;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : Value, UsageError, InterpreterFailure;

    private uint nextFixture;
    private class Fixture {
        string root, first, second;
        this() {
            root = buildPath(tempDir(), "ysh-d-hash-" ~ to!string(getpid()) ~ "-" ~ to!string(nextFixture++));
            first = root ~ "/first";
            second = root ~ "/second";
            mkdirRecurse(first);
            mkdirRecurse(second);
            link(first ~ "/cachecmd", "/bin/true");
            link(second ~ "/cachecmd", "/bin/false");
        }
        void link(string path, string target = "/bin/true") {
            assert(symlink(target.toStringz(), path.toStringz()) == 0);
        }
        void finish() { rmdirRecurse(root); }
        Memory memory() {
            auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
            mem.initializeShellEnvironment();
            mem.setGlobal("PATH", Value.str(first));
            return mem;
        }
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string result, line;
        while ((line = file.readln()).length) result ~= line;
        return result;
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        auto mem = f.memory();
        assert(runHash(["cachecmd", f.first ~ "/cachecmd"], mem) == 0);
        mem.setGlobal("PATH", Value.str(f.second));
        assert(mem.searchPath.cachedLookup("cachecmd") == f.first ~ "/cachecmd");
        assert(mem.searchPath.lookupReflect("cachecmd", false) == [f.second ~ "/cachecmd"]);
        assert(runHash([], mem) == 0);
        assert(contents(mem.outputFile) == f.first ~ "/cachecmd\n" ~ f.first ~ "/cachecmd\n");
        remove(f.first ~ "/cachecmd");
        assert(runHash(["cachecmd"], mem) == 0, "a stale hit must not be revalidated");
        assert(runHash(["-r"], mem) == 0);
        assert(mem.searchPath.cachedLookup("cachecmd") == f.second ~ "/cachecmd");
        assert(runHash(["later"], mem) == 1);
        f.link(f.second ~ "/later");
        assert(mem.searchPath.cachedLookup("later") == f.second ~ "/later", "misses must not be cached");
        mem.searchPath.maybeRemoveEntry("later");
        remove(f.second ~ "/later");
        assert(mem.searchPath.cachedLookup("later") is null);
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        auto mem = f.memory();
        auto file = f.first ~ "/nonexec";
        write(file, "non executable file\n");
        assert(chmod(file.toStringz(), 420) == 0);
        auto fifo = f.first ~ "/fifo";
        assert(mkfifo(fifo.toStringz(), 493) == 0);
        foreach (path; [file, f.first, fifo]) {
            assert(mem.searchPath.lookupOne(path) == path);
            assert(mem.searchPath.lookupReflect(path, true).length == 0);
            assert(runHash([path], mem) == 0);
        }
        assert(mem.searchPath.lookupOne("nonexec") is null);
        assert(mem.searchPath.lookupOne("nonexec", false) == file);
        assert(mem.searchPath.lookupOne("fifo") is null);
        foreach (path; [f.first ~ "/cachecmd\0suffix", "\0missing"]) {
            bool failed;
            try { mem.searchPath.cachedLookup(path); }
            catch (InterpreterFailure error) { failed = true; }
            assert(failed, "a NUL pathname must fail before reaching libc's C string boundary");
            failed = false;
            try { mem.searchPath.lookupReflect(path, false); }
            catch (InterpreterFailure error) { failed = true; }
            assert(failed);
        }
        assert(mem.searchPath.lookupReflect("fifo", true).length == 0);
        assert(lookupExecutable("cachecmd", [f.first ~ "/"]) == f.first ~ "/cachecmd");
        assert(mem.searchPath.lookupOne("") is null);
        assert(mem.searchPath.lookupReflect("", true).length == 0);
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        auto mem = f.memory();
        assert(runHash(["cachecmd"], mem) == 0);
        foreach (words; [["-r", "extra"], ["-rx"], ["--help"]]) {
            bool rejected;
            try { runHash(words, mem); }
            catch (UsageError error) { rejected = error.status == 2; }
            assert(rejected);
            assert(mem.searchPath.cachedCommands().length == 1, "parse errors cannot clear the cache");
        }
        assert(runHash(["cachecmd", "-r", "", "a'b", "line\n", "\xff"], mem) == 1);
        assert(mem.searchPath.cachedCommands().length == 1);
        assert(contents(mem.errorFile) == "hash: '-r' not found\nhash: '' not found\n" ~
            "hash: \"a'b\" not found\nhash: 'line\\n' not found\nhash: '\\xff' not found\n");
        assert(runHash(["-rr", "--"], mem) == 0 && !mem.searchPath.cachedCommands().length);
        assert(runHash(["--", "cachecmd"], mem) == 0);
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        auto mem = f.memory();
        executeProgram("cachecmd; hash", mem);
        assert(mem.lastStatus == 0 && contents(mem.outputFile) == f.first ~ "/cachecmd\n");
        mem.setGlobal("PATH", Value.str(f.second));
        executeProgram("command cachecmd", mem);
        assert(mem.lastStatus == 0, "ordinary command execution must share hash's stale cache");
        executeProgram("command -v cachecmd", mem);
        assert(contents(mem.outputFile) == f.first ~ "/cachecmd\n" ~ f.second ~ "/cachecmd\n");
        mem.searchPath.clearCache();
        f.link(f.second ~ "/cat", "/bin/false");
        assert(runHash(["cat"], mem) == 0);
        executeProgram("command -p cat /dev/null", mem);
        assert(mem.lastStatus == 0);
        assert(mem.searchPath.cachedCommands() == [f.second ~ "/cat"]);
        mem.searchPath.clearCache();
        executeProgram("command -p cat /dev/null", mem);
        assert(mem.lastStatus == 0 && !mem.searchPath.cachedCommands().length);
        executeProgram("cachecmd", mem);
        assert(mem.lastStatus == 1 && mem.searchPath.cachedCommands() == [f.second ~ "/cachecmd"]);
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        auto mem = f.memory();
        auto before = getcwd();
        scope (exit) chdir(before);
        chdir(f.first);
        mem.setGlobal("PATH", Value.str(""));
        assert(mem.searchPath.cachedLookup("cachecmd") == "cachecmd");
        chdir(f.second);
        executeProgram("cachecmd", mem);
        assert(mem.lastStatus == 1, "relative cache values must stay relative across cd");
        mem.searchPath.clearCache();
        executeProgram("unset PATH", mem);
        assert(mem.searchPath.cachedLookup("cachecmd") is null, "unset PATH has no current-directory segment");
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        auto mem = f.memory();
        assert(runHash(["cachecmd"], mem) == 0);
        executeProgram("( hash -r ); hash -r | read ignored", mem);
        assert(mem.searchPath.cachedCommands() == [f.first ~ "/cachecmd"]);
        executeProgram("echo input | hash -r", mem);
        assert(!mem.searchPath.cachedCommands().length, "the last pipeline command executes in the parent");
        executeProgram("cachecmd | read ignored", mem);
        assert(!mem.searchPath.cachedCommands().length, "a pipeline producer cannot populate the parent's cache");
        executeProgram("echo input | cachecmd", mem);
        assert(mem.lastStatus == 0 && mem.searchPath.cachedCommands() == [f.first ~ "/cachecmd"]);
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        auto mem = f.memory();
        auto env = mem.get("ENV").dictValue;
        env.set("PATH", Value.str(f.first));
        assert(runHash(["cachecmd"], mem) == 0);
        executeProgram("shvar PATH='" ~ f.second ~ "' { hash cachecmd }", mem);
        assert(mem.lastStatus == 0 && env.get("PATH").stringValue == f.first);
        assert(mem.searchPath.cachedCommands() == [f.second ~ "/cachecmd"]);
        executeProgram("shvar PATH=unused invalid { echo wrong }", mem);
        assert(mem.lastStatus == 2 && !mem.searchPath.cachedCommands().length);
        mem.options.set("ysh:all", true);
        env.set("PATH", Value.nullValue());
        assert(mem.searchPath.lookupOne("cachecmd") is null);
        assert(mem.searchPath.lookupOne(f.first ~ "/cachecmd") == f.first ~ "/cachecmd");
        env.erase("PATH");
        auto defaults = mem.builtins.cells["__defaults__"].value.dictValue;
        defaults.set("PATH", Value.str(f.first));
        assert(mem.searchPath.lookupOne("cachecmd") == f.first ~ "/cachecmd");
        defaults.set("PATH", Value.integer(42));
        assert(mem.searchPath.lookupOne("cachecmd") is null);
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        auto mem = f.memory();
        assert(runHash(["cachecmd"], mem) == 0);
        executeProgram("hash -r (42)", mem);
        assert(mem.lastStatus == 2 && mem.searchPath.cachedCommands() == [f.first ~ "/cachecmd"]);
        mem.setGlobal("PATH", Value.str(f.second));
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            executeProgram("exec cachecmd", mem);
            _exit(99);
        }
        int status;
        assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "exec must use the interpreter's existing cache before PATH");
        assert(mem.searchPath.cachedCommands() == [f.first ~ "/cachecmd"]);
    }

    unittest {
        auto f = new Fixture();
        scope (exit) f.finish();
        foreach (redirect; ["2>/dev/full", "2>&-"]) {
            auto missing = "hash-no-such-command " ~ redirect;
            auto mem = f.memory();
            executeProgram("( " ~ missing ~ "; echo resumed ); echo child=$?", mem);
            assert(contents(mem.outputFile) == "child=2\n");
            assert(!mem.searchPath.cachedCommands().length);

            mem = f.memory();
            executeProgram(missing ~ " | read ignored", mem);
            assert(mem.pipelineStatus == [2, 1]);

            mem = f.memory();
            executeProgram(missing ~ " & wait $!", mem);
            assert(mem.lastStatus == 2);

            mem = f.memory();
            executeProgram("captured=$(" ~ missing ~ "; echo resumed)", mem);
            assert(mem.lastStatus == 2 && mem.wordVariable("captured") == "");
            assert(contents(mem.outputFile) == "" && !mem.searchPath.cachedCommands().length);
        }
    }
}
