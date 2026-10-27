module yshd.traps;

import std.algorithm : sort;
import std.conv : to;
import std.string : toUpper, startsWith;
import std.format : format;
import std.utf : decode, UTFException;
import core.stdc.errno : errno;
import core.stdc.string : strerror;
import core.stdc.signal : sig_atomic_t;
import core.sys.posix.signal;
import yshd.libc_patterns : SIGWINCH;

import yshd.state : Memory;
import yshd.program : executeProgram, parseProgram, ProgramParser, ShellExit;
import yshd.func_proc : ProcReturn;
import yshd.value : UsageError, YshError;

// The C signal callback only writes sig_atomic_t storage. D parsing, allocation,
// output and user code run after control returns to the interpreter.
private __gshared sig_atomic_t[1024] pendingSignals;
private __gshared sig_atomic_t pendingCount;
private __gshared sig_atomic_t lastSignal;
private __gshared sig_atomic_t pendingOverflow;

private extern(C) void recordSignal(int number) nothrow @nogc {
    lastSignal = number;
    auto count = pendingCount;
    if (count < pendingSignals.length) {
        pendingSignals[count] = number;
        pendingCount = count + 1;
    } else pendingOverflow = 1;
}

struct SignalName { string name; int number; }

SignalName[] signalNames() {
    SignalName[] result = [
        SignalName("ABRT", SIGABRT), SignalName("ALRM", SIGALRM),
        SignalName("BUS", SIGBUS), SignalName("CHLD", SIGCHLD),
        SignalName("CONT", SIGCONT), SignalName("FPE", SIGFPE),
        SignalName("HUP", SIGHUP), SignalName("ILL", SIGILL),
        SignalName("INT", SIGINT), SignalName("KILL", SIGKILL),
        SignalName("PIPE", SIGPIPE), SignalName("QUIT", SIGQUIT),
        SignalName("SEGV", SIGSEGV), SignalName("STOP", SIGSTOP),
        SignalName("TERM", SIGTERM), SignalName("TSTP", SIGTSTP),
        SignalName("TTIN", SIGTTIN), SignalName("TTOU", SIGTTOU),
        SignalName("USR1", SIGUSR1), SignalName("USR2", SIGUSR2),
        SignalName("SYS", SIGSYS), SignalName("TRAP", SIGTRAP),
        SignalName("URG", SIGURG), SignalName("VTALRM", SIGVTALRM),
        SignalName("XCPU", SIGXCPU), SignalName("XFSZ", SIGXFSZ),
        SignalName("WINCH", SIGWINCH)
    ];
    sort!((a, b) => a.number < b.number)(result);
    return result;
}

private bool hookName(string name) {
    return name == "EXIT" || name == "ERR" || name == "DEBUG" || name == "RETURN";
}

string parseSignal(string text, bool legacy = true) {
    bool digits = text.length != 0;
    foreach (c; text) if (c < '0' || c > '9') digits = false;
    if (legacy && digits) {
        long number;
        try { number = to!long(text); }
        catch (Exception error) { throw new UsageError("overflowing signal number: " ~ text); }
        if (number == 0) return "EXIT";
        foreach (item; signalNames()) if (item.number == number) return item.name;
    } else {
        text = text.toUpper();
        if (hookName(text)) return text;
        if (text.startsWith("SIG")) text = text[3 .. $];
        foreach (item; signalNames()) if (item.name == text) return text;
    }
    throw new UsageError("expected signal or hook, got '" ~ text ~ "'");
}

private int signalNumber(string name) {
    foreach (item; signalNames()) if (item.name == name) return item.number;
    throw new UsageError("unknown signal " ~ name);
}

private struct TrapAction { bool ignored; string source; string displayCode; }

string shellQuote(string source) {
    // data_lang/j8.h:BourneShellEncodeOne/BashDollarEncodeOne. Fall back
    // to $'' for controls, quotes, backslashes and invalid UTF-8 bytes.
    bool plain = true;
    for (size_t i; i < source.length;) {
        if (source[i] < 0x20 || source[i] == '\'' || source[i] == '\\') plain = false;
        try { decode(source, i); }
        catch (UTFException error) { plain = false; ++i; }
    }
    if (plain) return "'" ~ source ~ "'";
    string encoded = "$'";
    for (size_t i; i < source.length;) {
        auto c = source[i];
        switch (c) {
        case '\\': encoded ~= "\\\\"; ++i; continue;
        case '\'': encoded ~= "\\'"; ++i; continue;
        case '\b': encoded ~= "\\b"; ++i; continue;
        case '\f': encoded ~= "\\f"; ++i; continue;
        case '\n': encoded ~= "\\n"; ++i; continue;
        case '\r': encoded ~= "\\r"; ++i; continue;
        case '\t': encoded ~= "\\t"; ++i; continue;
        default: break;
        }
        if (c < 0x20) { encoded ~= format("\\u%04x", cast(ubyte)c); ++i; continue; }
        auto begin = i;
        try { decode(source, i); encoded ~= source[begin .. i]; }
        catch (UTFException error) { encoded ~= format("\\x%02x", cast(ubyte)c); i = begin + 1; }
    }
    return encoded ~ "'";
}

class TrapState {
    private TrapAction[string] actions;
    private string[] hooks;
    private sigaction_t[int] originalActions;
    private bool mainInitialized;
    private bool runningSignals;
    private bool runningDebug;
    private bool runningErr;

    private void install(int number, bool ignored) {
        sigaction_t action, previous;
        sigfillset(&action.sa_mask);
        action.sa_flags = 0; // Blocking operations must return on interruption.
        action.sa_handler = ignored ? SIG_IGN : &recordSignal;
        if (sigaction(number, &action, &previous) < 0)
            throw new UsageError("cannot set signal handler: " ~ to!string(strerror(errno)));
        if (number !in originalActions) originalActions[number] = previous;
    }

    void initializeMain() {
        if (mainInitialized) return;
        mainInitialized = true;
        sigaction_t previous;
        if (sigaction(SIGINT, null, &previous) == 0 && previous.sa_handler != SIG_IGN)
            install(SIGINT, false);
    }

    void restore() {
        foreach (number, ref action; originalActions) sigaction(number, &action, null);
        originalActions = null;
        mainInitialized = false;
        clearPending();
    }

    private static int[] takePending() {
        int[1024] copy;
        sigset_t blocked, previous;
        sigfillset(&blocked);
        sigprocmask(SIG_BLOCK, &blocked, &previous);
        auto count = pendingCount;
        foreach (i; 0 .. count) copy[i] = pendingSignals[i];
        auto overflow = pendingOverflow;
        pendingCount = 0;
        pendingOverflow = 0;
        lastSignal = 0;
        sigprocmask(SIG_SETMASK, &previous, null);
        if (overflow) throw new YshError("signal queue overflow", 2);
        return copy[0 .. count].dup;
    }

    static void clearPending() { pendingCount = 0; pendingOverflow = 0; lastSignal = 0; }
    static int interruptSignal() { return lastSignal; }
    bool hasActions() const { return actions.length != 0; }

    void clearForSubProgram(bool inheritErr) {
        TrapAction err;
        auto saved = "ERR" in actions;
        bool hasErr = saved !is null && inheritErr;
        if (hasErr) err = *saved;
        // POSIX keeps ignored dispositions across fork/exec, but resets caught
        // handlers for a new shell subprogram. Keep the original SIG_IGN state.
        foreach (name, action; actions) if (!hookName(name) && !action.ignored) {
            sigaction_t reset;
            sigemptyset(&reset.sa_mask);
            reset.sa_handler = SIG_DFL;
            sigaction(signalNumber(name), &reset, null);
        }
        if (mainInitialized && "INT" !in actions) {
            sigaction_t reset;
            sigemptyset(&reset.sa_mask);
            reset.sa_handler = SIG_DFL;
            sigaction(SIGINT, &reset, null);
        }
        actions = null;
        hooks = [];
        if (hasErr) { actions["ERR"] = err; hooks ~= "ERR"; }
        originalActions = null;
        runningSignals = runningDebug = runningErr = false;
        mainInitialized = false;
        clearPending();
    }

    private void add(string name, TrapAction action) {
        if (hookName(name)) {
            if (name !in actions) hooks ~= name;
        } else install(signalNumber(name), action.ignored);
        actions[name] = action;
    }

    private void remove(string name) {
        actions.remove(name);
        if (hookName(name)) {
            foreach (i, existing; hooks) if (existing == name) { hooks = hooks[0 .. i] ~ hooks[i+1 .. $]; break; }
        } else {
            auto number = signalNumber(name);
            if (number == SIGINT && mainInitialized) install(number, false);
            else {
                sigaction_t reset;
                sigemptyset(&reset.sa_mask);
                reset.sa_handler = SIG_DFL;
                sigaction(number, &reset, null);
            }
        }
    }

    void runPending(Memory mem) {
        if (runningSignals) return;
        runningSignals = true;
        scope (exit) runningSignals = false;
        foreach (number; takePending()) {
            string name;
            foreach (item; signalNames()) if (number == item.number) { name = item.name; break; }
            auto action = name in actions;
            if (action is null) {
                if (number == SIGINT) throw new ShellExit(130);
                continue;
            }
            if (action.ignored) continue;
            auto source = action.source;
            auto status = mem.lastStatus;
            auto pipeline = mem.pipelineStatus.dup;
            auto line = mem.currentLine;
            scope (exit) { mem.lastStatus = status; mem.pipelineStatus = pipeline; mem.currentLine = line; }
            executeProgram(source, mem);
        }
    }

    void runDebug(Memory mem) {
        auto action = "DEBUG" in actions;
        if (action is null || action.ignored || runningDebug || !mem.atTopLevel()) return;
        auto source = action.source;
        auto status = mem.lastStatus;
        auto pipeline = mem.pipelineStatus.dup;
        auto savedLine = mem.preserveLine;
        mem.preserveLine = true;
        runningDebug = true;
        scope (exit) { runningDebug = false; mem.lastStatus = status; mem.pipelineStatus = pipeline; mem.preserveLine = savedLine; }
        executeProgram(source, mem);
    }

    void runErr(Memory mem) {
        auto action = "ERR" in actions;
        if (action is null || action.ignored || runningErr || mem.lastStatus == 0 || mem.errexitSuppression || mem.errTrapSuppression)
            return;
        if (!mem.atTopLevel() && !mem.options.get("errtrace")) return;
        auto source = action.source;
        auto status = mem.lastStatus;
        runningErr = true;
        auto savedLine = mem.preserveLine;
        mem.preserveLine = true;
        scope (exit) { runningErr = false; mem.lastStatus = status; mem.preserveLine = savedLine; }
        executeProgram(source, mem);
    }

    int finish(Memory mem, int status) {
        mem.lastStatus = status;
        try { runPending(mem); }
        catch (ShellExit control) { status = control.status; mem.lastStatus = status; }
        catch (YshError error) { mem.errorFile.writeln("ysh-d: ", error.msg); }
        auto action = "EXIT" in actions;
        if (action !is null && !action.ignored) {
            auto source = action.source;
            try { executeProgram(source, mem); }
            catch (ShellExit control) { status = control.status; }
            catch (ProcReturn control) { status = control.status; }
            catch (YshError error) { mem.errorFile.writeln("ysh-d: ", error.msg); }
        }
        return status;
    }

    int builtin(string[] words, bool hasBlock, string body, Memory mem) {
        bool addFlag, removeFlag, ignoreFlag, printFlag, listFlag;
        size_t index;
        for (; index < words.length; ++index) {
            auto word = words[index];
            if (word == "--") { ++index; break; }
            if (word == "--add") addFlag = true;
            else if (word == "--remove") removeFlag = true;
            else if (word == "--ignore") ignoreFlag = true;
            else if (word == "-p") printFlag = true;
            else if (word == "-l") listFlag = true;
            else if (word.length > 1 && word[0] == '-') throw new UsageError("trap: invalid flag " ~ word);
            else break;
        }
        auto rest = words[index .. $];
        if (addFlag && !hasBlock) throw new UsageError("trap --add requires a block");
        if (hasBlock && !addFlag) throw new UsageError("trap block requires --add");
        if (addFlag) parseProgram(body, mem.returnMode, mem.options);
        if (listFlag) {
            foreach (name; ["EXIT", "ERR", "RETURN", "DEBUG"]) mem.outputFile.writeln("   ", name);
            foreach (item; signalNames()) mem.outputFile.writef("%2d SIG%s\n", item.number, item.name);
            return 0;
        }
        if (printFlag || (!rest.length && !addFlag && !ignoreFlag && !removeFlag && !mem.options.get("simple_trap_builtin"))) {
            void print(string name, string display) {
                auto action = actions[name];
                mem.outputFile.writeln("trap -- ", action.ignored ? "''" : shellQuote(action.displayCode), " ", display);
            }
            foreach (name; hooks) print(name, name);
            foreach (item; signalNames()) if (item.name in actions) print(item.name, "SIG" ~ item.name);
            return 0;
        }
        bool legacy = !(addFlag || removeFlag || ignoreFlag);
        TrapAction action;
        if (legacy) {
            if (mem.options.get("simple_trap_builtin")) throw new UsageError("expected --add, --remove, -l, or -p (simple_trap_builtin)");
            if (!rest.length) return 0;
            bool numeric = rest[0].length != 0;
            foreach (c; rest[0]) if (c < '0' || c > '9') numeric = false;
            if (rest[0] == "-") { removeFlag = true; rest = rest[1 .. $]; }
            else if (numeric) removeFlag = true;
            else if (rest.length == 1 && rest[0].length) { removeFlag = true; }
            else {
                action.source = rest[0];
                action.ignored = rest[0].length == 0;
                rest = rest[1 .. $];
                if (!action.ignored) {
                    try {
                        auto parser = new ProgramParser(action.source, true, mem.returnMode, false, mem.options);
                        parser.parse();
                        action.displayCode = parser.commandSourceCode();
                    }
                    catch (YshError error) { mem.errorFile.writeln("ysh-d: ", error.msg); return 1; }
                }
            }
        } else { action.ignored = ignoreFlag; action.source = body; action.displayCode = "<unknown>"; }
        foreach (word; rest) {
            auto name = parseSignal(word, legacy);
            if (removeFlag) remove(name);
            else {
                if (name == "STOP" || name == "KILL") {
                    mem.errorFile.writeln("Signal '", word, "' can't be handled");
                    return 2;
                }
                if (name == "RETURN") mem.errorFile.writeln("osh warning: The 'RETURN' hook isn't implemented");
                add(name, action);
            }
        }
        return 0;
    }
}
