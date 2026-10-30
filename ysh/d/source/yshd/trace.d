module yshd.trace;

import std.array : replicate;
import std.conv : to;
import std.string : join;
import yshd.state : Memory;
import yshd.value : Value, ValueKind, YshError;
import yshd.options : ShellOptions;
import yshd.program : evaluateDoubleQuotedExpression, validateDoubleQuoted, Errexit, ShellExit;
import yshd.traps : shellQuote;

/// D equivalents of core/runtime.asdl's process trace reasons.
enum TraceProcessKind { external, forkWait, commandSub, processSub, hereDoc, fork, pipelinePart }

/// data_lang/j8.h:CanOmitQuotes and j8_lite.MaybeShellEncode. Trace argv
/// uses shell encoding, including quoted keywords and invalid UTF-8 bytes.
string maybeShellQuote(string value) {
    bool plain = value.length != 0 && value != "true" && value != "false" && value != "null";
    foreach (ch; value) {
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                (ch >= '0' && ch <= '9') || ch == '.' || ch == '/' || ch == '_' || ch == '-')) {
            plain = false;
            break;
        }
    }
    return plain ? value : shellQuote(value);
}

private string encodedArgv(string[] argv) {
    string[] words;
    foreach (word; argv) words ~= maybeShellQuote(word);
    return words.join(" ");
}

/// core/dev.py:Tracer. Trace depth belongs to the execution context even
/// while xtrace is disabled; forked interpreters retain it and add their PID.
class TraceState {
    private size_t depth;
    private string pidText;
    private bool evaluating;
    string[] commandArgv;

    private bool enabled(Memory mem) { return !evaluating && mem.options.get("xtrace"); }
    private bool rich(Memory mem) { return enabled(mem) && mem.options.get("xtrace_rich"); }
    private bool legacy(Memory mem) { return enabled(mem) && !mem.options.get("no_xtrace_osh"); }

    private string prefix(string punctuation, Memory mem) {
        auto cell = mem.getCell("PS4");
        auto ps4 = cell !is null && cell.value.kind == ValueKind.stringValue ? cell.value.stringValue : "";
        auto status = mem.lastStatus;
        auto pipeline = mem.pipelineStatus.dup;
        auto epoch = mem.commandSubEpoch;
        auto subStatus = mem.commandSubLastStatus;
        auto line = mem.currentLine;
        auto regex = mem.regexMatch;
        auto savedPreserve = mem.preserveLine;
        evaluating = true;
        auto numbers = [ShellOptions.number("xtrace")];
        mem.options.push(numbers, false);
        mem.pushEnclosed(mem.currentFrame);
        scope (exit) {
            mem.popFrame();
            mem.options.pop(numbers);
            mem.lastStatus = status;
            mem.pipelineStatus = pipeline;
            mem.commandSubEpoch = epoch;
            mem.commandSubLastStatus = subStatus;
            mem.currentLine = line;
            mem.regexMatch = regex;
            mem.preserveLine = savedPreserve;
            evaluating = false;
        }
        mem.preserveLine = true;
        mem.regexMatch = null;
        mem.pipelineStatus = [];
        mem.declareLocal("_error", Value.dict());
        mem.declareLocal("SHX_indent", Value.str(mem.options.get("xtrace_rich") ? "  ".replicate(depth) : ""));
        mem.declareLocal("SHX_punct", Value.str(punctuation));
        mem.declareLocal("SHX_pid_str", Value.str(pidText));
        try { validateDoubleQuoted(ps4, mem.options); }
        catch (YshError error) { return "<ERROR: Can't parse PS4: " ~ error.msg ~ ">"; }
        try { return evaluateDoubleQuotedExpression(ps4, mem); }
        catch (Errexit error) {
            return "<Runtime error: " ~ (error.diagnostic.length ? error.diagnostic :
                "Command failed with status " ~ to!string(error.status)) ~ ">";
        }
        catch (YshError error) { return "<Runtime error: " ~ error.msg ~ ">"; }
        catch (ShellExit error) { if (error.status == 130) return "<Ctrl-C>"; throw error; }
    }

    private void emit(string punctuation, string text, Memory mem) {
        mem.errorFile.write(prefix(punctuation, mem), text);
        mem.errorFile.flush();
    }

    void simpleCommand(string[] argv, Memory mem) {
        if (legacy(mem) && !mem.options.get("xtrace_rich"))
            emit("+", encodedArgv(argv) ~ "\n", mem);
    }

    void builtin(string[] argv, Memory mem) {
        if (!argv.length || argv[0] == "eval" || argv[0] == "source" || argv[0] == "." ||
                argv[0] == "use" || argv[0] == "wait" || argv[0] == "exit") return;
        if (rich(mem)) emit(".", "builtin " ~ encodedArgv(argv) ~ "\n", mem);
    }

    void exec(string[] argv, Memory mem) {
        if (rich(mem)) emit(".", "exec " ~ encodedArgv(argv) ~ "\n", mem);
    }

    void processStart(int pid, TraceProcessKind kind, string[] argv, Memory mem) {
        if (!rich(mem)) return;
        string text;
        final switch (kind) {
        case TraceProcessKind.external: text = "command " ~ to!string(pid) ~ ": " ~ encodedArgv(argv); break;
        case TraceProcessKind.forkWait: text = "forkwait " ~ to!string(pid); break;
        case TraceProcessKind.commandSub: text = "command sub " ~ to!string(pid); break;
        case TraceProcessKind.processSub: text = "proc sub " ~ to!string(pid); break;
        case TraceProcessKind.hereDoc: text = "here doc " ~ to!string(pid); break;
        case TraceProcessKind.fork: text = "fork " ~ to!string(pid); break;
        case TraceProcessKind.pipelinePart: text = "part " ~ to!string(pid); break;
        }
        emit("|", text ~ "\n", mem);
    }

    void processEnd(int pid, int status, Memory mem) {
        if (rich(mem)) emit(";", "process " ~ to!string(pid) ~ ": status " ~ to!string(status) ~ "\n", mem);
    }

    void newProcess(int pid) { pidText = " " ~ to!string(pid); ++depth; }

    void push(string label, string[] argv, Memory mem) {
        if (rich(mem)) {
            string text = label;
            if (label == "proc" || label == "module-invoke") text ~= argv.length ? " " ~ encodedArgv(argv) : "";
            else if (label == "source" || label == "use" || label == "wait")
                text ~= argv.length > 1 ? " " ~ encodedArgv(argv[1 .. $]) : "";
            emit(">", text ~ "\n", mem);
        }
        ++depth;
    }

    void pop(string label, string arg, Memory mem) {
        assert(depth);
        --depth;
        if (rich(mem)) emit("<", label ~ (arg.length ? " " ~ maybeShellQuote(arg) : "") ~ "\n", mem);
    }

    void control(string keyword, long value, Memory mem) {
        if (enabled(mem)) emit("+", keyword ~ " " ~ to!string(value) ~ "\n", mem);
    }

    void sourceCode(string source, Memory mem) {
        if (!legacy(mem)) return;
        import std.string : indexOf;
        auto end = source.indexOf('\n');
        emit("+", end < 0 ? source ~ "\n" : source[0 .. end] ~ " ...\n", mem);
    }

    void assignment(string name, string operation, Value value, Memory mem) {
        if (!legacy(mem)) return;
        import yshd.pretty : prettyValue;
        auto text = value.kind == ValueKind.stringValue ? maybeShellQuote(value.stringValue) : prettyValue(value);
        emit("+", name ~ operation ~ text ~ "\n", mem);
    }
}

/// Synchronous trace context; unwinds on returns, failures and exceptions.
struct TraceScope {
    private Memory mem;
    private string label;
    private string arg;
    @disable this(this);
    this(Memory mem, string label, string[] argv = []) {
        this.mem = mem;
        this.label = label;
        if ((label == "proc" || label == "module-invoke") && argv.length) arg = argv[0];
        else if ((label == "source" || label == "use") && argv.length > 1) arg = argv[1];
        mem.trace.push(label, argv, mem);
    }
    ~this() { if (mem !is null) mem.trace.pop(label, arg, mem); }
}
