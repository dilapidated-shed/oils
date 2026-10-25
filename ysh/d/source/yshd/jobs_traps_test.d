module yshd.jobs_traps_test;

version (Posix) version (unittest) {
    import std.stdio : File;
    import std.file : getcwd;
    import core.sys.posix.unistd : fork, _exit, getpid, usleep;
    import core.sys.posix.signal : kill, SIGUSR1;
    import core.sys.posix.sys.wait : waitpid;
    import yshd.state : Memory;
    import yshd.options : ShellOptions;
    import yshd.program : executeProgram, parseProgram, ShellExit;
    import yshd.process : runExternal;

    private string contents(File file) {
        file.flush(); file.rewind();
        string text;
        while (!file.eof()) text ~= file.readln();
        return text;
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        auto directory = getcwd();
        executeProgram(`
            var parent = [1]
            fork { call parent->append(2); cd /; exit 23 }
            wait $!
            echo waited=$?
            forkwait { setglobal parent = [99]; cd /; exit 42 }
            echo foreground=$?
            fork { sleep 0.02; exit 9 }
            fork { exit 7 }
            wait -n
            echo next=$?
            wait
            echo all=$?
            wait -n
            echo empty=$?
        `, mem);
        assert(getcwd() == directory);
        assert(mem.get("parent").listValue.length == 1);
        assert(mem.get("parent").listValue.items[0].integerValue == 1);
        auto actual = contents(output);
        assert(actual == "waited=23\nforeground=42\nnext=7\nall=0\nempty=127\n" ||
            actual == "waited=23\nforeground=42\nnext=9\nall=0\nempty=127\n", actual);
        assert(mem.jobs.waitBuiltin(["12345678"], mem) == 127);
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        scope (exit) mem.traps.restore();
        mem.traps.initializeMain();
        executeProgram("var seen = 0; trap --add USR1 { echo trap=$?; setglobal seen += 1 }", mem);
        mem.lastStatus = 17;
        mem.pipelineStatus = [4, 9];
        assert(kill(getpid(), SIGUSR1) == 0);
        assert(mem.get("seen").integerValue == 0); // callback only queues
        mem.traps.runPending(mem);
        assert(mem.get("seen").integerValue == 1);
        assert(mem.lastStatus == 17 && mem.pipelineStatus == [4, 9]);

        auto parent = getpid();
        auto sender = fork();
        assert(sender >= 0);
        if (sender == 0) { usleep(10_000); kill(parent, SIGUSR1); _exit(0); }
        int raw;
        scope (exit) waitpid(sender, &raw, 0);
        assert(runExternal(["sleep", "0.04"], mem) == 0);
        assert(mem.get("seen").integerValue == 2);
        auto actual = contents(output);
        assert(actual == "trap=17\ntrap=17\n", actual);
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        scope (exit) mem.traps.restore();
        executeProgram(`
            trap 'echo parent-exit=$?' EXIT
            trap 'echo err=$LINENO:$?' ERR
            ( trap -p; false; echo child )
            echo $(trap -p; echo captured)
            trap -p | cat
            false
        `, mem);
        assert(mem.traps.finish(mem, 5) == 5);
        assert(contents(output) == "child\ncaptured\nerr=7:1\nparent-exit=5\n");
        executeProgram("trap 'exit 42' EXIT", mem);
        assert(mem.traps.finish(mem, 5) == 42);
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        // Failed opens return a command status and obey errexit. They do not
        // execute the redirected command or prevent later OSH commands.
        executeProgram("echo wrong >/no/such/ysh-d-test/directory/file; echo status=$?", mem);
        assert(contents(output) == "status=1\n");
        bool stopped;
        mem.errexit = true;
        try { executeProgram("true </no/such/ysh-d-test/file; echo wrong", mem); }
        catch (ShellExit control) { stopped = control.status == 1; }
        assert(stopped);
        // The syntax path must neither fork nor install a signal handler.
        parseProgram("sleep 10 & trap 'echo unexpected' EXIT; wait");
        auto ysh = new ShellOptions(true);
        bool rejected;
        try { parseProgram("echo bad &", mem.returnMode, ysh); }
        catch (Exception error) { rejected = true; }
        assert(rejected);
    }

    version (linux) unittest {
        import std.file : readLink, readText, dirEntries, SpanMode, FileException;
        import std.path : baseName;
        import std.conv : to;
        import std.string : split, startsWith;
        import core.sys.posix.unistd : getpgid, getpgrp;
        import core.sys.posix.signal : SIGTERM;
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.jobs.controlEnabled = true;
        executeProgram("sleep 5 | sleep 5 &", mem);
        auto group = getpgid(cast(int)mem.lastBackgroundPid);
        assert(group > 0 && group != getpgrp());
        scope (exit) {
            kill(-group, SIGTERM);
            mem.jobs.waitBuiltin([], mem);
        }
        // Some containers mount an outer PID namespace's /proc. Resolve the
        // direct child's NSpid instead of assuming /proc uses getpid() IDs.
        string parent;
        foreach (line; readText("/proc/self/status").split("\n"))
            if (line.startsWith("Pid:")) parent = line.split()[$ - 1];
        bool replaced;
        foreach (attempt; 0 .. 50) {
            foreach (entry; dirEntries("/proc", SpanMode.shallow)) {
                auto name = baseName(entry.name);
                bool numeric = name.length != 0;
                foreach (ch; name) if (ch < '0' || ch > '9') numeric = false;
                if (!numeric) continue;
                try {
                    string parentPid, namespacePid;
                    foreach (line; readText(entry.name ~ "/status").split("\n")) {
                        if (line.startsWith("PPid:")) parentPid = line.split()[$ - 1];
                        if (line.startsWith("NSpid:")) namespacePid = line.split()[$ - 1];
                    }
                    if (parentPid == parent && namespacePid == to!string(mem.lastBackgroundPid) &&
                            baseName(readLink(entry.name ~ "/exe")) == "sleep") { replaced = true; break; }
                } catch (FileException error) {} // unrelated /proc entries may exit
            }
            if (replaced) break;
            usleep(1_000);
        }
        assert(replaced, "$! must identify the last pipeline process, with no hidden evaluator PID");
        assert(kill(-group, SIGTERM) == 0);
        assert(mem.jobs.waitBuiltin([to!string(mem.lastBackgroundPid)], mem) == 128 + SIGTERM);
    }
}
