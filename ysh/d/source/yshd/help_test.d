module yshd.help_test;

version (unittest) {
    import std.stdio : File;
    import yshd.help : HelpBuiltin, printEmbeddedHelp, printTopicHeader, printHelpFlag;
    import yshd.help_resources : ResourceLoader, ResourceError;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : InterpreterFailure, UsageError;

    private class Cards : ResourceLoader {
        string[string] files;
        string[] requested;
        this() { files["oils-version.txt"] = "test-version\r\nignored\n"; }
        string get(string path) {
            requested ~= path;
            auto contents = path in files;
            if (contents is null) throw new ResourceError("missing " ~ path);
            return *contents;
        }
    }

    private string contents(File file) {
        file.flush();
        file.rewind();
        string result;
        char[256] buffer;
        while (true) {
            auto data = file.rawRead(buffer);
            if (!data.length) break;
            result ~= data;
        }
        return result;
    }

    private Memory memory(HelpBuiltin help) {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        mem.helpBuiltin = help;
        return mem;
    }

    unittest {
        auto loader = new Cards();
        auto output = File.tmpfile();
        printTopicHeader("literal\nname", output);
        assert(contents(output) == "~~~ literal\nname ~~~\n\n");
        output = File.tmpfile();
        loader.files["_devbuild/help/bytes"] = "a\0b\n\n";
        assert(printEmbeddedHelp(loader, "bytes", output));
        assert(contents(output) == "~~~ bytes ~~~\n\na\0b\n\n\n");
        output = File.tmpfile();
        loader.files["_devbuild/help/empty"] = "";
        assert(printEmbeddedHelp(loader, "empty", output));
        assert(contents(output) == "~~~ empty ~~~\n\n\n");
        output = File.tmpfile();
        assert(!printEmbeddedHelp(loader, "missing", output));
        assert(contents(output) == "");
    }

    unittest {
        auto loader = new Cards();
        loader.files["_devbuild/help/osh-usage"] = "usage\n";
        loader.files["_devbuild/help/shell-flags"] = "flags\n";
        auto output = File.tmpfile();
        printHelpFlag(loader, "osh-usage", output);
        assert(contents(output) == "Oils test-version\r\t\thttps://oils.pub/\n\n" ~
            "~~~ osh-usage ~~~\n\nusage\n\n~~~ shell-flags ~~~\n\nflags\n\n");
        loader.files.remove("_devbuild/help/shell-flags");
        output = File.tmpfile();
        bool failed;
        try { printHelpFlag(loader, "osh-usage", output); }
        catch (InterpreterFailure error) { failed = true; }
        assert(failed && contents(output) == "Oils test-version\r\t\thttps://oils.pub/\n\n" ~
            "~~~ osh-usage ~~~\n\nusage\n\n");
        output = File.tmpfile();
        failed = false;
        try { printHelpFlag(loader, "missing-usage", output); }
        catch (InterpreterFailure error) { failed = true; }
        assert(failed && contents(output) == "Oils test-version\r\t\thttps://oils.pub/\n\n");
    }

    unittest {
        auto loader = new Cards();
        loader.files["_devbuild/help/read"] = "wrong route\n";
        string[string] metadata = ["read": "builtin-io", "empty-chapter": "", "embedded": null,
            "OILS-ERR-7": "chapter-wins"];
        auto help = new HelpBuiltin("ysh", loader, metadata);
        auto mem = memory(help);
        assert(help.run(["read", "--bad", "ignored"], mem) == 0);
        assert(contents(mem.outputFile) == "~~~ read ~~~\n\n" ~
            "    https://oils.pub/release/test-version\r/doc/ref/chap-builtin-io.html#read\n\n");
        assert(loader.requested == ["oils-version.txt"], "metadata must precede file loading");
        mem.outputFile = File.tmpfile();
        assert(help.run(["empty-chapter"], mem) == 0);
        assert(contents(mem.outputFile) == "~~~ empty-chapter ~~~\n\n" ~
            "    https://oils.pub/release/test-version\r/doc/ref/chap-.html#empty-chapter\n\n");
        mem.outputFile = File.tmpfile();
        assert(help.run(["OILS-ERR-7"], mem) == 0);
        assert(contents(mem.outputFile) == "~~~ OILS-ERR-7 ~~~\n\n" ~
            "    https://oils.pub/release/test-version\r/doc/ref/chap-chapter-wins.html#OILS-ERR-7\n\n");
        loader.files["_devbuild/help/embedded"] = "embedded body";
        mem.outputFile = File.tmpfile();
        assert(help.run(["embedded"], mem) == 0);
        assert(contents(mem.outputFile) == "~~~ embedded ~~~\n\nembedded body\n");
    }

    unittest {
        auto loader = new Cards();
        auto help = new HelpBuiltin("ysh", loader);
        auto mem = memory(help);
        assert(help.run(["OiLs-ErRoR?\xff"], mem) == 0);
        assert(contents(mem.outputFile) == "\n    https://oils.pub/release/test-version\r/doc/error-catalog.html#oils-error?\xff\n\n");
        assert(loader.requested == ["oils-version.txt"]);
        foreach (topic, expected; ["": "''", "a'b": "\"a'b\"", "a'\"b": "'a\\'\"b'",
                "line\n\t\r\\\xff": "'line\\n\\t\\r\\\\\\xff'", "+x": "'+x'", "-": "'-'"]) {
            mem.errorFile = File.tmpfile();
            assert(help.run([topic], mem) == 1);
            assert(contents(mem.errorFile) == "no help topics match " ~ expected ~ "\n");
        }
    }

    unittest {
        auto loader = new Cards();
        loader.files["_devbuild/help/help"] = "help body\n";
        loader.files["_devbuild/help/osh-chapters"] = "osh index\n";
        loader.files["_devbuild/help/ysh-chapters"] = "ysh index\n";
        foreach (language; ["osh", "ysh"]) {
            auto help = new HelpBuiltin(language, loader);
            auto mem = memory(help);
            loader.files["oils-version.txt"] = "changed";
            mem.options.set("ysh:all", true);
            mem.argumentZero = "different-shell";
            assert(help.run([], mem) == 0);
            auto versionString = language == "osh" ? "test-version\r" : "changed";
            assert(contents(mem.outputFile) == "~~~ help ~~~\n\nhelp body\n\n~~~ " ~ language ~
                "-chapters ~~~\n\n" ~ language ~ " index\n\nAll docs: https://oils.pub/release/" ~ versionString ~ "/doc/\n\n");
        }
        auto minimal = memory(new HelpBuiltin("ysh", new Cards()));
        bool failed;
        try { minimal.helpBuiltin.run([], minimal); }
        catch (InterpreterFailure error) { failed = true; }
        assert(failed && contents(minimal.errorFile) == "no help topics match 'help'\n");
        loader.files.remove("_devbuild/help/osh-chapters");
        auto missingIndex = memory(new HelpBuiltin("osh", loader));
        failed = false;
        try { missingIndex.helpBuiltin.run([], missingIndex); }
        catch (InterpreterFailure error) { failed = true; }
        assert(failed && contents(missingIndex.outputFile) == "~~~ help ~~~\n\nhelp body\n\n");
        assert(contents(missingIndex.errorFile) == "no help topics match 'osh-chapters'\n");
    }

    unittest {
        auto loader = new Cards();
        auto help = new HelpBuiltin("ysh", loader);
        auto mem = memory(help);
        string[] flags = ["--help", "-x", "-0", "-xy"];
        string[] messages = ["doesn't accept flag --", "doesn't accept flag -x",
            "doesn't accept flag -Z", "doesn't accept flag -x"];
        foreach (index, flag; flags) {
            bool rejected;
            try { help.run([flag], mem); }
            catch (UsageError error) { rejected = error.msg == messages[index]; }
            assert(rejected);
        }
        assert(loader.requested == ["oils-version.txt"]);
        assert(help.run(["--", "-x", "anything"], mem) == 1);
        assert(contents(mem.errorFile) == "no help topics match '-x'\n");
        assert(help.run(["--", "oils-err-42", "--help"], mem) == 0);
    }

    unittest {
        auto loader = new Cards();
        loader.files["_devbuild/help/topic"] = "body";
        auto mem = memory(new HelpBuiltin("ysh", loader));
        executeProgram("help topic; builtin help topic; command help topic", mem);
        assert(mem.lastStatus == 0);
        assert(contents(mem.outputFile) == "~~~ topic ~~~\n\nbody\n~~~ topic ~~~\n\nbody\n~~~ topic ~~~\n\nbody\n");
        mem.options.set("ysh:all", true);
        mem.errexit = false;
        mem.outputFile = File.tmpfile();
        executeProgram("help topic (1); echo $?", mem);
        assert(mem.lastStatus == 0 && contents(mem.outputFile) == "2\n");
        assert(contents(mem.errorFile) == "ysh-d: got unexpected typed args\n");
        mem.errorFile = File.tmpfile();
        executeProgram("help topic { echo wrong }; echo $?", mem);
        assert(contents(mem.outputFile) == "2\n2\n");
        assert(contents(mem.errorFile) == "ysh-d: got unexpected typed args\n");
    }

    unittest {
        import std.exception : ErrnoException;
        import yshd.value : ClosedDescriptorError;
        auto loader = new Cards();
        auto help = new HelpBuiltin("ysh", loader);
        auto mem = memory(help);
        mem.outputFile = File.init;
        assert(help.run(["missing"], mem) == 1);
        assert(contents(mem.errorFile) == "no help topics match 'missing'\n",
            "a missing resource does not inspect or write stdout");
        mem.errorFile = File.init;
        bool rawIo;
        try { help.run(["missing"], mem); }
        catch (ErrnoException error) { rawIo = true; }
        assert(rawIo, "a failed missing-topic diagnostic must escape the builtin");
        loader.files["_devbuild/help/exists"] = "body";
        bool outputFailed;
        try { help.run(["exists"], mem); }
        catch (ClosedDescriptorError error) { outputFailed = true; }
        assert(outputFailed);
    }

    version (linux) unittest {
        import core.sys.posix.stdlib : posix_openpt, grantpt, unlockpt, ptsname;
        import core.sys.posix.fcntl : open, O_RDWR, O_NOCTTY;
        import core.sys.posix.unistd : close, read;
        import core.sys.posix.termios : termios, tcgetattr, tcsetattr, TCSANOW, OPOST;
        import core.sys.posix.poll : poll, pollfd, POLLIN;
        auto master = posix_openpt(O_RDWR | O_NOCTTY);
        assert(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0);
        scope (exit) close(master);
        auto slave = open(ptsname(master), O_RDWR | O_NOCTTY);
        assert(slave >= 0);
        termios state;
        assert(tcgetattr(slave, &state) == 0);
        state.c_oflag &= ~OPOST;
        assert(tcsetattr(slave, TCSANOW, &state) == 0);
        File output;
        output.fdopen(slave, "w");
        printTopicHeader("topic", output);
        output.flush();
        enum expected = "\x1b[7m topic \x1b[0;0m\n\n";
        string actual;
        while (actual.length < expected.length) {
            pollfd descriptor;
            descriptor.fd = master;
            descriptor.events = POLLIN;
            assert(poll(&descriptor, 1, 1000) == 1);
            char[128] buffer;
            auto count = read(master, buffer.ptr, buffer.length);
            assert(count > 0);
            actual ~= buffer[0 .. count];
        }
        assert(actual == expected);
    }
}
