module yshd.exec_test;

version (unittest) {
    import std.stdio : File;
    import std.conv : to;
    import yshd.program : executeProgram, ShellExit;
    import yshd.state : Memory;

    private string contents(File file) {
        file.flush();
        file.rewind();
        string result;
        while (!file.eof()) result ~= file.readln();
        return result;
    }

    unittest {
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram(`
            exec 9>&1
            exec 1>&-
            echo wrong
            echo status=$? >&9
            exec 1>&9
            exec 9>&-
            echo restored
            exec 0<&-
            read unavailable
            echo input=$?
            alias keep='exec'
            keep 6<<< aliased
            read -u 6 alias_value
            echo "$alias_value"
            exec 6<&-
            exec -a 7<<< rejected
            echo option=$?
        `, mem);
        assert(contents(output) == "status=1\nrestored\ninput=1\naliased\noption=2\n");
        assert(!mem.hasExtraDescriptor(7));
        assert(!mem.descriptorFile(0).isOpen);
    }

    unittest {
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram(`
            exec 3<<EOF
one
two
EOF
            read -u 3 first
            { read -u 3 inner } 3<<< temporary
            read -u 3 second
            echo "$first:$inner:$second"
            exec -- 4<&3
            exec 3<&-
            read -u 4 exhausted
            echo status=$?
            exec 4<&-
        `, mem);
        assert(contents(output) == "one:temporary:two\nstatus=1\n");
        assert(contents(errors) == "");
        assert(mem.physicalDescriptor(3) == -1 && mem.physicalDescriptor(4) == -1);
    }

    unittest {
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram(`
            {
                exec
                exec 4<<< survives
                { exec 3<<< replacement; read -u 3 inner } 3<<< nested
                read -u 3 outer
                echo "$inner:$outer"
            } 3<<< outer
            read -u 4 kept
            echo "$kept"
            exec 4<&-
        `, mem);
        assert(contents(output) == "replacement:outer\nsurvives\n");
        assert(!mem.hasExtraDescriptor(3));
        // An exec in a procedure owns an empty redirect frame: it must not
        // promote the caller's temporary descriptor scope.
        executeProgram(`proc noop { exec }; noop 5<<< scoped`, mem);
        assert(!mem.hasExtraDescriptor(5));
        // Standard streams obey the same per-target restoration rule.
        executeProgram(`{ exec 1>&2 } 0<<< ignored; echo retained`, mem);
        assert(contents(errors) == "retained\n");
        mem.outputFile = output;
    }

    version (linux) unittest {
        import core.sys.posix.unistd : fork, _exit;
        import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto input = File.tmpfile();
        input.write("must-not-appear\n");
        input.rewind();
        auto mem = new Memory(input, output, errors);
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            executeProgram(`exec 1>&-; exec /usr/bin/cat; echo wrong-return`, mem);
            _exit(99);
        }
        int status;
        assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 1);
        assert(contents(output) == "");
        assert(contents(errors).length != 0);
    }

    version (linux) unittest {
        import std.file : dirEntries, SpanMode;
        size_t descriptorCount() {
            size_t count;
            foreach (entry; dirEntries("/proc/self/fd", SpanMode.shallow)) ++count;
            return count;
        }
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        auto before = descriptorCount();
        foreach (_; 0 .. 500) executeProgram(`exec 8</dev/null`, mem);
        executeProgram(`exec 8<&-`, mem);
        assert(descriptorCount() == before, "permanent descriptor rebinding leaked open files");
    }

    version (linux) unittest {
        import core.sys.posix.unistd : fork, _exit, getpid;
        import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            executeProgram(`trap 'echo wrong-exit-trap' EXIT; exec /usr/bin/readlink /proc/self; echo wrong-return`, mem);
            _exit(99);
        }
        int status;
        assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        assert(contents(output) == to!string(child) ~ "\n", "exec forked or resumed shell evaluation");
        assert(contents(errors) == "");
    }

    version (linux) unittest {
        import std.file : readText;
        import std.string : startsWith;
        import core.sys.posix.unistd : pipe, fork, _exit, close, write, usleep, alarm;
        import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
        import core.sys.posix.signal : kill, SIGPIPE, SIGUSR1;
        alarm(8);
        scope (exit) alarm(0);
        int[2] descriptors;
        assert(pipe(descriptors) == 0);
        File input;
        input.fdopen(descriptors[0], "r");
        auto output = File.tmpfile();
        auto mem = new Memory(input, output, File.tmpfile());
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            close(descriptors[1]);
            executeProgram(`trap '' PIPE USR1; exec -a NATIVE-EXEC-ARGV0 /usr/bin/cat`, mem);
            _exit(99);
        }
        bool replaced;
        foreach (_; 0 .. 2000) {
            auto command = readText("/proc/" ~ to!string(child) ~ "/cmdline");
            if (command.startsWith("NATIVE-EXEC-ARGV0\0")) { replaced = true; break; }
            usleep(1000);
        }
        auto text = "preserved\n";
        if (replaced) {
            assert(kill(child, SIGPIPE) == 0 && kill(child, SIGUSR1) == 0);
            assert(write(descriptors[1], text.ptr, text.length) == text.length);
        }
        // A failing argv/PID check still releases stdin and reaps the child.
        close(descriptors[1]);
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(replaced, "exec -a did not replace the actual process argv[0]");
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "exec changed an ignored signal disposition");
        assert(contents(output) == text);
    }
}
