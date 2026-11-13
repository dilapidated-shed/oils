module yshd.redirection_fd_test;

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
        auto input = File.tmpfile();
        input.write("default\n");
        input.rewind();
        auto output = File.tmpfile();
        auto mem = new Memory(input, output, File.tmpfile());
        executeProgram(`
            {
                read -u 3 first
                read standard
                { read -u 3 inner } 3<<< inner
                read -u 3 second
                echo "$first:$standard:$inner:$second"
            } 3<<EOF
outer-first
outer-second
EOF
        `, mem);
        assert(contents(output) == "outer-first:default:inner:outer-second\n");
        assert(mem.inputFile == input && mem.extraDescriptors.length == 0);
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, File.tmpfile());
        // Left-to-right duplication keeps the original open-file description,
        // even after the original shell descriptor is rebound or closed.
        executeProgram(`
            {
                { read -u 4 first; read -u 3 second; echo "$first:$second" } 4<&3 3<<< replacement
                { read -u 4 remaining; echo "$remaining" } 4<&3 3<&-
                read -u 3 last
                echo status=$?
            } 3<<EOF
original
remaining
EOF
        `, mem);
        assert(contents(output) == "original:replacement\nremaining\nstatus=1\n");
        assert(mem.extraDescriptors.length == 0);

        executeProgram(`read -u 8 wrong 8<&2147483646; echo failed=$?`, mem);
        assert(mem.lastStatus == 0 && mem.extraDescriptors.length == 0);
        assert(mem.getCell("wrong") is null);
        executeProgram(`read -u 2147483647 too_high 2147483647<<< ignored; echo range=$?`, mem);
        assert(mem.lastStatus == 0 && mem.getCell("too_high") is null);
        assert(mem.extraDescriptors.length == 0);
        // Error and control-flow unwinding restore the descriptor namespace.
        try { executeProgram(`exit 23 8<<< temporary`, mem); }
        catch (ShellExit stopped) { assert(stopped.status == 23); }
        assert(mem.extraDescriptors.length == 0);
    }

    version (linux) unittest {
        import yshd.process : runExternal;
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(File.tmpfile(), output, errors);
        executeProgram(`
            {
                /usr/bin/cat /dev/fd/3
                /usr/bin/printf external >&4
                echo builtin >&4
            } 3<<< input 4>&1
        `, mem);
        assert(contents(output) == "input\nexternalbuiltin\n", contents(output));
        assert(contents(errors) == "");
        assert(mem.extraDescriptors.length == 0);
        // A later child must not inherit a redirection from the completed
        // command, even when its number collides with a host File descriptor.
        assert(runExternal(["/usr/bin/cat", "/dev/fd/4"], mem) != 0);
    }
}
