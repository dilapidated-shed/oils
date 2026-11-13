module yshd.terminal_read_test;

version (linux) version (unittest) {
    import core.sys.posix.stdlib : posix_openpt, grantpt, unlockpt, ptsname;
    import core.sys.posix.fcntl : open, O_RDWR, O_NOCTTY;
    import core.sys.posix.unistd : fork, _exit, write, usleep, close, alarm, getpid;
    import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
    import core.sys.posix.termios : termios, tcgetattr, tcsetattr, TCSANOW, ECHO, ICANON;
    import core.sys.posix.poll : poll, pollfd, POLLIN;
    import core.sys.posix.signal : kill, SIGUSR1;
    import std.stdio : File;
    import yshd.read_builtin : runReadBuiltin;
    import yshd.state : Memory;
    import yshd.program : executeProgram, ShellExit;

    private File terminal(out int master, out termios initial) {
        master = posix_openpt(O_RDWR | O_NOCTTY);
        assert(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0);
        auto slave = open(ptsname(master), O_RDWR | O_NOCTTY);
        assert(slave >= 0 && tcgetattr(slave, &initial) == 0);
        initial.c_lflag |= ECHO | ICANON;
        assert(tcsetattr(slave, TCSANOW, &initial) == 0);
        File file;
        file.fdopen(slave, "r+");
        return file;
    }

    private void waitForSilent(int slave) {
        foreach (_; 0 .. 2000) {
            termios state;
            if (tcgetattr(slave, &state) != 0) _exit(91);
            if (!(state.c_lflag & ECHO)) return;
            usleep(1000);
        }
        _exit(92);
    }

    unittest {
        alarm(5);
        scope (exit) alarm(0);
        int master;
        termios before, after;
        auto input = terminal(master, before);
        scope (exit) close(master);
        auto errors = File.tmpfile();
        auto mem = new Memory(input, File.tmpfile(), errors);
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            waitForSilent(input.fileno());
            auto text = "abc";
            _exit(write(master, text.ptr, text.length) == text.length ? 0 : 93);
        }
        runReadBuiltin(["-sn3", "-p", "Prompt: ", "secret"], null, false, mem);
        int status;
        assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        assert(mem.lastStatus == 0 && mem.get("secret").stringValue == "abc");
        assert(tcgetattr(input.fileno(), &after) == 0 && after.c_lflag == before.c_lflag);
        assert(after.c_cc == before.c_cc && after.c_iflag == before.c_iflag);
        errors.rewind();
        assert(errors.readln() == "Prompt: ");
        // The secret must never have been echoed to the master side.
        pollfd descriptor;
        descriptor.fd = master;
        descriptor.events = POLLIN;
        assert(poll(&descriptor, 1, 0) == 0);
    }

    unittest {
        alarm(5);
        scope (exit) alarm(0);
        int master;
        termios before, after;
        auto input = terminal(master, before);
        scope (exit) close(master);
        auto mem = new Memory(input, File.tmpfile(), File.tmpfile());
        executeProgram(`trap 'exit 23' USR1`, mem);
        scope (exit) executeProgram(`trap - USR1`, mem);
        auto parent = getpid();
        auto child = fork();
        assert(child >= 0);
        if (child == 0) {
            waitForSilent(input.fileno());
            _exit(kill(parent, SIGUSR1) == 0 ? 0 : 94);
        }
        bool exited;
        try { runReadBuiltin(["-s"], null, false, mem); }
        catch (ShellExit stopped) { exited = stopped.status == 23; }
        int status;
        assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        assert(exited && tcgetattr(input.fileno(), &after) == 0 && after.c_lflag == before.c_lflag);
    }
}
