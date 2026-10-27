module yshd.state;

import std.format : format;
import std.process : environment;
import std.stdio : File, stderr, stdin, stdout;

import yshd.value : Value, ValueKind, YshDict, YshError, FatalRuntimeError, YshPlace, StructuredError;
import std.bigint : BigInt;
import yshd.options : ShellOptions;
import yshd.dirs : DirectoryStack;
import yshd.traps : TrapState;
import yshd.jobs : JobTable;

enum ReturnMode { shell, functionValue, procValue }

public import yshd.value : RegexMatch;

/// A YSH variable cell. The shape follows core/runtime.asdl's Cell closely
/// enough for the D translation to preserve identity when a frame is enclosed.
class Cell {
    bool readOnly;
    bool exported;
    Value value;

    this(Value value, bool readOnly = false) {
        this.value = value;
        this.readOnly = readOnly;
    }
}

/// Reference frames are insertion-ordered dictionaries of cells. Rebinding
/// preserves order; removing and reinserting a name puts it at the end.
class FrameCells {
    private Cell[string] values;
    private string[] names;
    Cell* find(string name) { return name in values; }
    Cell get(string name, Cell fallback = null) {
        auto cell = find(name);
        return cell is null ? fallback : *cell;
    }
    void set(string name, Cell cell) {
        if (name !in values) names ~= name;
        values[name] = cell;
    }
    void remove(string name) {
        if (!values.remove(name)) return;
        foreach (index, item; names) if (item == name) {
            names = names[0 .. index] ~ names[index + 1 .. $];
            break;
        }
    }
    int opApply(scope int delegate(string, Cell) visit) {
        foreach (name; names) {
            auto status = visit(name, values[name]);
            if (status) return status;
        }
        return 0;
    }
}

class BuiltinRegistry {
    Cell[string] cells;
    YshDict shellFunctions;
    this() { shellFunctions = new YshDict(); }
}

/// The enclosed field is core/state.py's lexical __E__ link. Dynamic callers
/// remain in Memory's active frame stack and are never captured by this link.
class Frame {
    FrameCells cells;

    @property Frame enclosed() {
        auto cell = cells.find("__E__");
        if (cell is null) return null;
        if ((*cell).value.kind != ValueKind.frameValue)
            throw new FatalRuntimeError("Lexical enclosure should be a Frame");
        return (*cell).value.frameValue;
    }

    this(Frame enclosed = null) {
        cells = new FrameCells();
        if (enclosed !is null) cells.set("__E__", new Cell(Value.frame(enclosed)));
    }
}

/// A Place captures the precise current frame, independent of later calls.
/// SetPlace in core/state.py writes that frame, including a new local name.
class FramePlace : YshPlace {
    Frame frame;
    string name;
    this(Frame frame, string name) { this.frame = frame; this.name = name; }
    override void assign(Value value) {
        auto cell = frame.cells.find(name);
        if (cell is null) frame.cells.set(name, new Cell(value));
        else (*cell).value = value;
    }
}

private Cell lookupFrame(Frame frame, string name, bool declaration, ref Frame foundFrame) {
    if (frame is null) {
        return null;
    }

    auto found = frame.cells.find(name);
    if (found !is null) {
        foundFrame = frame;
        return *found;
    }

    // var/const declarations deliberately do not walk through the enclosure:
    // they may shadow an enclosed name.
    if (!declaration && frame.enclosed !is null) {
        return lookupFrame(frame.enclosed, name, false, foundFrame);
    }

    return null;
}

/// The beginning of core/state.py:Mem in D.
///
/// It already preserves the distinction needed by YSH between a global frame,
/// the current local frame, and a recursively enclosed lexical frame. More of
/// Mem's registers/environment/process state will move here as those execution
/// paths are translated.
class Memory {
    TrapState traps;
    JobTable jobs;
    bool canReplaceProcess;
    Frame globalFrame;
    Frame currentFrame;
    private Frame[] frameStack;
    BuiltinRegistry builtins;
    private size_t loopDepth;
    int lastStatus;
    size_t commandSubEpoch;
    int commandSubLastStatus;
    int[] pipelineStatus;
    size_t errTrapSuppression;
    size_t currentLine = 1;
    bool preserveLine;
    private struct SourceRoot { string source; size_t firstLine; }
    private SourceRoot[] sourceRoots;

    void registerSource(string source) {
        auto address = cast(size_t)source.ptr;
        foreach (root; sourceRoots) {
            auto base = cast(size_t)root.source.ptr;
            if (address >= base && address + source.length <= base + root.source.length) return;
        }
        sourceRoots ~= SourceRoot(source, 1);
    }

    void registerDerivedSource(string source, string original, size_t offset) {
        auto saved = currentLine;
        auto savedPreserve = preserveLine;
        preserveLine = false;
        setSourcePosition(original, offset);
        sourceRoots ~= SourceRoot(source, currentLine);
        currentLine = saved;
        preserveLine = savedPreserve;
    }

    void setSourcePosition(string source, size_t offset) {
        if (preserveLine) return;
        auto address = cast(size_t)source.ptr;
        foreach (root; sourceRoots) {
            auto base = cast(size_t)root.source.ptr;
            if (address < base || address + source.length > base + root.source.length) continue;
            currentLine = root.firstLine;
            foreach (ch; root.source[0 .. address - base + offset]) if (ch == '\n') ++currentLine;
            return;
        }
        currentLine = 1;
        foreach (ch; source[0 .. offset]) if (ch == '\n') ++currentLine;
    }
    ReturnMode returnMode;
    RegexMatch regexMatch;
    YshDict[] contextStack;
    ShellOptions options;
    @property bool errexit() const { return options.get("errexit"); }
    @property void errexit(bool enabled) { options.set("errexit", enabled); }
    @property bool nounset() const { return options.get("nounset"); }
    @property void nounset(bool enabled) { options.set("nounset", enabled); }
    @property bool pipefail() const { return options.get("pipefail"); }
    @property void pipefail(bool enabled) { options.set("pipefail", enabled); }
    // Conditions and individual pipeline stages defer errexit to their owner.
    // A counter preserves nested suppression.
    size_t errexitSuppression;
    // core/state.py:Mem keeps $0 separate from mutable/global/local ARGV.
    string argumentZero = "ysh-d";
    string workingDirectory;
    DirectoryStack directoryStack;
    string[] shellArguments;
    long rootPid;
    long shellStartTime;
    bool shellEnvironmentInitialized;
    long lastBackgroundPid = -1;
    bool isMain = true;
    bool[string] sourceGuards;
    Value[string] diskModules;
    Value[string] embeddedModules;
    string[] sourceDirectories;

    bool atTopLevel() const { return frameStack.length == 1; }

    Frame indexedFrame(BigInt index) {
        auto normalized = index < 0 ? index + frameStack.length : index;
        if (normalized < 0 || normalized >= frameStack.length)
            throw new StructuredError(3, format("Invalid frame %s", index), new YshDict());
        import std.conv : to;
        return frameStack[to!size_t(normalized)];
    }

    void pushSourceDirectory(string path) {
        import std.path : absolutePath, dirName;
        sourceDirectories ~= dirName(absolutePath(path));
    }

    string simpleShellVariable(char name, bool quoted = false) {
        import std.conv : to;
        import std.array : join;
        switch (name) {
        case '?': return to!string(lastStatus);
        case '#': return to!string(shellArguments.length);
        case '$': return to!string(rootPid);
        case '!':
            if (lastBackgroundPid >= 0) return to!string(lastBackgroundPid);
            if (nounset) throw new FatalRuntimeError("Undefined special parameter $!");
            return "";
        case '@': case '*':
            if (name != '*' || !quoted) {
                if (options.get("strict_array"))
                    throw new FatalRuntimeError("Illegal array word part (strict_array)");
                return shellArguments.join(" ");
            }
            auto ifs = findDynamicCell("IFS");
            string separator = " ";
            if (ifs !is null) {
                if (ifs.value.kind != ValueKind.stringValue)
                    throw new FatalRuntimeError("IFS should be a string");
                auto text = ifs.value.stringValue;
                separator = text.length ? text[0 .. 1] : "";
            }
            return shellArguments.join(separator);
        case '-':
            string flags;
            foreach (index, option; ["interactive", "errexit", "noglob", "noexec", "nounset", "verbose", "xtrace", "noclobber"])
                if (options.get(option)) flags ~= "iefnuvxC"[index];
            return flags;
        default:
            assert(name >= '0' && name <= '9');
            return name == '0' ? argumentZero : shellArgument(name - '0');
        }
    }

    string shellArgument(size_t index) {
        if (index && index <= shellArguments.length) return shellArguments[index - 1];
        if (nounset) throw new FatalRuntimeError("Undefined positional argument");
        return "";
    }

    // Command aliases are shell parser state, not lexical-frame variables.
    // Keep them across source/eval and calls that share this Memory.
    string[string] aliases;

    // Suppress recursive re-expansion while reparsing an alias's source.
    // This permits the ordinary `alias echo='echo prefix'` pattern.
    string[] aliasExpansionStack;
    File inputFile;
    File outputFile;
    File errorFile;

    this() {
        this(stdin, stdout, stderr);
    }

    this(File outputFile, File errorFile) {
        this(stdin, outputFile, errorFile);
    }

    this(File inputFile, File outputFile, File errorFile) {
        this.inputFile = inputFile;
        this.outputFile = outputFile;
        this.errorFile = errorFile;
        options = new ShellOptions();
        traps = new TrapState();
        jobs = new JobTable();
        import std.file : getcwd;
        workingDirectory = getcwd();
        import core.sys.posix.unistd : getpid;
        rootPid = getpid();
        import core.stdc.time : time;
        shellStartTime = time(null);
        directoryStack = new DirectoryStack();
        globalFrame = new Frame();
        currentFrame = globalFrame;
        frameStack = [globalFrame];

        // core/state.py exposes the process environment through the YSH ENV
        // object.  Keep it as a mutable Dict so setglobal ENV.NAME updates the
        // environment inherited by subsequently spawned child processes.
        auto env = new YshDict();
        foreach (name, value; environment.toAA()) {
            env.set(name, Value.str(value));
        }
        globalFrame.cells.set("ENV", new Cell(Value.dictRef(env)));
        globalFrame.cells.set("ARGV", new Cell(Value.list([])));
        // InitDefaultVars sets IFS even when no_init_globals is enabled.
        globalFrame.cells.set("IFS", new Cell(Value.str(" \t\n")));
        globalFrame.cells.set("_error", new Cell(Value.dict()));
        globalFrame.cells.set("NAN", new Cell(Value.floating(double.nan)));
        globalFrame.cells.set("INFINITY", new Cell(Value.floating(double.infinity)));
        import yshd.expr : builtinNamespaces, builtinFunctionNames, builtinFunctionValue;
        builtins = new BuiltinRegistry();
        foreach (name, value; builtinNamespaces()) builtins.cells[name] = new Cell(value);
        foreach (name; builtinFunctionNames) builtins.cells[name] = new Cell(builtinFunctionValue(name));
        import yshd.module_ysh : moduleInvokeValue;
        builtins.cells["module-invoke"] = new Cell(moduleInvokeValue());
        auto builtinProperties = new YshDict();
        import yshd.value : YshObject;
        auto builtinObject = Value.object(new YshObject(null, builtinProperties));
        foreach (name, cell; builtins.cells) builtinProperties.set(name, cell.value);
        builtinProperties.set("__builtins__", builtinObject);
        builtins.cells["__builtins__"] = new Cell(builtinObject);
    }

    void initializeArguments(string argumentZero, string[] arguments) {
        this.argumentZero = argumentZero;
        shellArguments = arguments.dup;
        Value[] values;
        foreach (argument; arguments) {
            values ~= Value.str(argument);
        }
        globalFrame.cells.set("ARGV", new Cell(Value.list(values)));
    }

    /// OSH imports exported cells; YSH's no_init_globals leaves ENV as the
    /// sole initial environment owner. Later option changes keep both stores.
    void initializeShellEnvironment() {
        shellEnvironmentInitialized = true;
        if (options.get("no_init_globals")) return;
        foreach (name, value; get("ENV").dictValue) {
            if (globalFrame.cells.find(name) !is null) continue;
            auto cell = new Cell(value);
            cell.exported = true;
            globalFrame.cells.set(name, cell);
        }
    }

    /// core/sh_init.py:InitVarsAfterEnv. OSH exports PWD even in an empty
    /// environment. YSH's no_init_globals keeps only the private cwd register.
    void initializeDirectory() {
        if (options.get("no_init_globals")) return;
        import core.sys.posix.sys.stat : stat_t, stat;
        import std.string : toStringz;
        auto env = get("ENV").dictValue;
        if (auto inherited = env.find("PWD")) {
            auto path = inherited.stringValue;
            stat_t here, there;
            if (path.length && path[0] == '/' && stat(".", &here) == 0 &&
                    stat(path.toStringz(), &there) == 0 && here.st_dev == there.st_dev && here.st_ino == there.st_ino)
                workingDirectory = path;
        }
        setGlobal("PWD", Value.str(workingDirectory));
        env.set("PWD", Value.str(workingDirectory));
        directoryStack.replace(workingDirectory);
    }

    /// Calls have a new local frame but retain their defining global frame.
    /// A fresh Memory's placeholder globals must not intercept setglobal.
    void useGlobalFrame(Frame frame) {
        assert(frameStack.length == 1);
        globalFrame = frame;
        currentFrame = frame;
        frameStack = [frame];
    }

    Frame setActiveGlobalFrame(Frame frame) {
        auto previous = globalFrame;
        globalFrame = frame;
        frameStack[0] = frame;
        if (frameStack.length == 1) currentFrame = frame;
        return previous;
    }

    string getEnv(string name, string fallback = "") {
        if (!options.get("env_obj")) {
            auto cell = getCell(name);
            if (cell !is null) return cell.value.kind == ValueKind.stringValue ? cell.value.stringValue : fallback;
            if (shellEnvironmentInitialized) return fallback;
        }
        auto env = get("ENV");
        if (env.kind != ValueKind.dict) {
            throw new YshError("ENV must be a Dict");
        }
        auto found = env.dictValue.find(name);
        if (found is null) {
            return fallback;
        }
        if (found.kind != ValueKind.stringValue) {
            throw new YshError(format("ENV.%s must be a Str", name));
        }
        return found.stringValue;
    }

    string[string] childEnvironment() {
        auto env = get("ENV");
        if (env.kind != ValueKind.dict) {
            throw new YshError("ENV must be a Dict");
        }

        string[string] result;
        foreach (name, value; env.dictValue) {
            if (value.kind != ValueKind.stringValue) {
                throw new YshError(format("ENV.%s must be a Str", name));
            }
            result[name] = value.stringValue;
        }
        if (!options.get("env_obj") && shellEnvironmentInitialized) result = null;
        if (!options.get("no_exported")) foreach (frame; frameStack) foreach (name, cell; frame.cells) {
            if (cell.exported && cell.value.kind == ValueKind.stringValue) result[name] = cell.value.stringValue;
        }
        // ENV overlays exported cells in ysh:upgrade, as GetEnv does in the
        // reference. A removed ENV property must not revive a host variable.
        if (options.get("env_obj")) foreach (name, value; env.dictValue) result[name] = value.stringValue;
        return result;
    }

    Value get(string name) {
        if (name == "PIPESTATUS") {
            auto values = new YshDict();
            import std.conv : to;
            foreach (i, status; pipelineStatus) values.set(to!string(i), Value.str(to!string(status)));
            return Value.shellArray(values);
        }
        if (name == "_this_dir") {
            if (!sourceDirectories.length) throw new FatalRuntimeError("$_this_dir is not defined");
            return Value.str(sourceDirectories[$ - 1]);
        }
        if (name == "_pipeline_status") {
            Value[] statuses;
            foreach (status; pipelineStatus) statuses ~= Value.integer(status);
            return Value.list(statuses);
        }
        Frame ignored;
        auto cell = lookupLocalOrGlobal(name, ignored);
        if (cell is null) {
            throw new FatalRuntimeError(format("Undefined variable '%s'", name));
        }
        return cell.value;
    }

    Cell getCell(string name) {
        Frame ignored;
        return lookupLocalOrGlobal(name, ignored, options.get("dynamic_scope"));
    }

    Cell findDynamicCell(string name) {
        Frame found;
        foreach_reverse (frame; frameStack)
            if (auto cell = lookupFrame(frame, name, false, found)) return cell;
        return null;
    }

    Cell findGlobalCell(string name) {
        Frame found;
        return lookupFrame(globalFrame, name, false, found);
    }

    /// Shell-word lookup differs from a YSH expression's required binding.
    string wordVariable(string name) {
        import yshd.value : stringify;
        if (name == "LINENO") { import std.conv : to; return to!string(currentLine); }
        if (name == "BASHPID") { import std.conv : to; import core.sys.posix.unistd : getpid; return to!string(getpid()); }
        if (name == "_this_dir") {
            if (!sourceDirectories.length && !nounset) return "";
            return stringify(get(name));
        }
        auto cell = getCell(name);
        if (cell !is null) {
            if (cell.value.kind == ValueKind.bashArrayValue || cell.value.kind == ValueKind.bashAssocValue) {
                if (auto first = cell.value.shellContainer.find("0")) return first.stringValue;
                if (nounset) throw new FatalRuntimeError("Undefined shell array element 0");
                return "";
            }
            return stringify(cell.value);
        }
        auto environmentValue = get("ENV").dictValue.find(name);
        if (environmentValue !is null) return stringify(*environmentValue);
        if (nounset) throw new FatalRuntimeError(format("Undefined variable '%s'", name));
        return "";
    }

    Value getLocal(string name) {
        Frame ignored;
        auto cell = lookupFrame(currentFrame, name, false, ignored);
        if (cell is null) {
            throw new FatalRuntimeError(format("Undefined local variable '%s'", name));
        }
        return cell.value;
    }

    Cell findLocal(string name) {
        Frame ignored;
        return lookupFrame(currentFrame, name, false, ignored);
    }

    void unsetLocal(string name) {
        Frame found;
        auto cell = lookupFrame(currentFrame, name, false, found);
        if (cell !is null) { requireWritable(name, cell); found.cells.remove(name); }
    }

    bool unsetShellVariable(string name) {
        Frame found;
        Cell cell;
        if (options.get("dynamic_scope")) {
            foreach_reverse (frame; frameStack) {
                cell = lookupFrame(frame, name, false, found);
                if (cell !is null) break;
            }
        } else cell = lookupFrame(currentFrame, name, false, found);
        if (cell is null) return false;
        requireWritable(name, cell);
        found.cells.remove(name);
        return true;
    }

    Value getGlobal(string name) {
        Frame ignored;
        auto cell = lookupFrame(globalFrame, name, false, ignored);
        if (cell is null) {
            throw new FatalRuntimeError(format("Undefined global variable '%s'", name));
        }
        return cell.value;
    }

    void declareLocal(string name, Value value, bool readOnly = false) {
        Frame foundFrame;
        auto cell = lookupFrame(currentFrame, name, true, foundFrame);
        if (cell !is null) {
            requireWritable(name, cell);
            cell.value = value;
            cell.readOnly = readOnly;
            return;
        }

        currentFrame.cells.set(name, new Cell(value, readOnly));
    }

    /// Runtime semantics of setvar: mutate a local/enclosed binding when one
    /// exists; otherwise create it in the current local frame. Static YSH
    /// checks that reject some undeclared names belong to the command checker,
    /// not this storage primitive.
    void setVar(string name, Value value) {
        Frame foundFrame;
        auto cell = lookupFrame(currentFrame, name, false, foundFrame);
        if (cell !is null) {
            requireWritable(name, cell);
            cell.value = value;
            return;
        }

        currentFrame.cells.set(name, new Cell(value));
    }

    void setShellVar(string name, Value value) {
        auto cell = getShellAssignmentCell(name);
        if (cell !is null) { requireWritable(name, cell); cell.value = value; }
        else (options.get("dynamic_scope") ? globalFrame : currentFrame).cells.set(name, new Cell(value));
    }

    Cell getShellAssignmentCell(string name) {
        Frame found;
        if (options.get("dynamic_scope")) {
            foreach_reverse (frame; frameStack)
                if (auto cell = lookupFrame(frame, name, false, found)) return cell;
            return null;
        }
        return lookupFrame(currentFrame, name, false, found);
    }

    void setGlobal(string name, Value value) {
        Frame foundFrame;
        auto cell = lookupFrame(globalFrame, name, false, foundFrame);
        if (cell !is null) {
            requireWritable(name, cell);
            cell.value = value;
            return;
        }

        globalFrame.cells.set(name, new Cell(value));
    }

    /// Enter a frame that can see an enclosing frame, matching
    /// ctx_EnclosedFrame's lexical link. Function/proc argument and module
    /// policy will be layered on this primitive instead of inventing a second
    /// scope model.
    Frame pushEnclosed(Frame enclosed) {
        auto frame = new Frame(enclosed);
        pushFrame(frame);
        return frame;
    }

    void pushFrame(Frame frame) {
        frameStack ~= frame;
        currentFrame = frame;
    }

    void popFrame() {
        if (frameStack.length == 1) {
            throw new YshError("can't pop the global frame");
        }
        frameStack.length = frameStack.length - 1;
        currentFrame = frameStack[$ - 1];
    }

    void enterLoop() {
        ++loopDepth;
    }

    void leaveLoop() {
        if (loopDepth == 0) {
            throw new YshError("can't leave a loop that is not active");
        }
        --loopDepth;
    }

    bool insideLoop() const {
        return loopDepth != 0;
    }

    private Cell lookupLocalOrGlobal(string name, ref Frame foundFrame, bool allowDynamic = false) {
        Cell cell;
        if (allowDynamic) {
            foreach_reverse (frame; frameStack)
                if (auto found = lookupFrame(frame, name, false, foundFrame)) return found;
        }
        cell = lookupFrame(currentFrame, name, false, foundFrame);
        if (cell !is null) {
            return cell;
        }

        if (currentFrame !is globalFrame) {
            cell = lookupFrame(globalFrame, name, false, foundFrame);
            if (cell !is null) return cell;
        }
        auto builtin = name in builtins.cells;
        if (builtin is null && name == "module-invoke") {
            import yshd.module_ysh : moduleInvokeValue;
            builtins.cells[name] = new Cell(moduleInvokeValue());
            builtin = name in builtins.cells;
        }
        if (builtin is null && name == "__sh_function__") {
            builtins.cells[name] = new Cell(Value.dictRef(builtins.shellFunctions));
            builtin = name in builtins.cells;
        }
        if (builtin is null) {
            import yshd.expr : builtinFunctionValue;
            auto value = builtinFunctionValue(name);
            if (value.kind == ValueKind.builtinFunctionValue) {
                builtins.cells[name] = new Cell(value);
                builtin = name in builtins.cells;
            }
        }
        return builtin is null ? null : *builtin;
    }

    private static void requireWritable(string name, Cell cell) {
        if (cell.readOnly) {
            throw new FatalRuntimeError(format("Can't assign to readonly value '%s'", name));
        }
    }
}

unittest {
    auto mem = new Memory();

    mem.declareLocal("x", Value.integer(1));
    assert(mem.get("x").integerValue == 1);

    mem.setVar("x", Value.integer(2));
    assert(mem.get("x").integerValue == 2);

    mem.declareLocal("c", Value.integer(3), true);
    bool rejected;
    try {
        mem.setVar("c", Value.integer(4));
    } catch (YshError error) {
        rejected = true;
    }
    assert(rejected);

    auto captured = mem.currentFrame;
    mem.pushEnclosed(captured);
    assert(mem.get("x").integerValue == 2);

    // A declaration shadows an enclosed binding.
    mem.declareLocal("x", Value.integer(10));
    assert(mem.get("x").integerValue == 10);
    mem.popFrame();
    assert(mem.get("x").integerValue == 2);
}
