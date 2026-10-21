module yshd.state;

import std.format : format;
import std.process : environment;
import std.stdio : File, stderr, stdin, stdout;

import yshd.value : Value, ValueKind, YshDict, YshError, FatalRuntimeError, YshPlace;
import yshd.options : ShellOptions;

enum ReturnMode { shell, functionValue, procValue }

public import yshd.value : RegexMatch;

/// A YSH variable cell. The shape follows core/runtime.asdl's Cell closely
/// enough for the D translation to preserve identity when a frame is enclosed.
class Cell {
    bool readOnly;
    Value value;

    this(Value value, bool readOnly = false) {
        this.value = value;
        this.readOnly = readOnly;
    }
}

/// A lexical frame. The enclosed field is the D equivalent of the __E__ frame
/// link used by core/state.py:_FrameLookup.
class Frame {
    Cell[string] cells;
    Frame enclosed;

    this(Frame enclosed = null) {
        this.enclosed = enclosed;
    }
}

/// A Place captures the precise current frame, independent of later calls.
/// SetPlace in core/state.py writes that frame, including a new local name.
class FramePlace : YshPlace {
    Frame frame;
    string name;
    this(Frame frame, string name) { this.frame = frame; this.name = name; }
    override void assign(Value value) {
        auto cell = name in frame.cells;
        if (cell is null) frame.cells[name] = new Cell(value);
        else (*cell).value = value;
    }
}

private Cell lookupFrame(Frame frame, string name, bool declaration, ref Frame foundFrame) {
    if (frame is null) {
        return null;
    }

    auto found = name in frame.cells;
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
    Frame globalFrame;
    Frame currentFrame;
    private Frame[] frameStack;
    private size_t loopDepth;
    int lastStatus;
    ReturnMode returnMode;
    RegexMatch regexMatch;
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
        globalFrame.cells["ENV"] = new Cell(Value.dictRef(env));
        globalFrame.cells["ARGV"] = new Cell(Value.list([]));
        globalFrame.cells["_error"] = new Cell(Value.dict());
        globalFrame.cells["NAN"] = new Cell(Value.floating(double.nan));
        globalFrame.cells["INFINITY"] = new Cell(Value.floating(double.infinity));
    }

    void initializeArguments(string argumentZero, string[] arguments) {
        this.argumentZero = argumentZero;
        Value[] values;
        foreach (argument; arguments) {
            values ~= Value.str(argument);
        }
        globalFrame.cells["ARGV"] = new Cell(Value.list(values));
    }

    /// Calls have a new local frame but retain their defining global frame.
    /// A fresh Memory's placeholder globals must not intercept setglobal.
    void useGlobalFrame(Frame frame) {
        assert(frameStack.length == 1);
        globalFrame = frame;
        currentFrame = frame;
        frameStack = [frame];
    }

    string getEnv(string name, string fallback = "") {
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
        return result;
    }

    Value get(string name) {
        Frame ignored;
        auto cell = lookupLocalOrGlobal(name, ignored);
        if (cell is null) {
            throw new FatalRuntimeError(format("Undefined variable '%s'", name));
        }
        return cell.value;
    }

    Cell getCell(string name) {
        Frame ignored;
        return lookupLocalOrGlobal(name, ignored);
    }

    /// Shell-word lookup differs from a YSH expression's required binding.
    string wordVariable(string name) {
        import yshd.value : stringify;
        auto cell = getCell(name);
        if (cell !is null) return stringify(cell.value);
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

        currentFrame.cells[name] = new Cell(value, readOnly);
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

        currentFrame.cells[name] = new Cell(value);
    }

    void setGlobal(string name, Value value) {
        Frame foundFrame;
        auto cell = lookupFrame(globalFrame, name, false, foundFrame);
        if (cell !is null) {
            requireWritable(name, cell);
            cell.value = value;
            return;
        }

        globalFrame.cells[name] = new Cell(value);
    }

    /// Enter a frame that can see an enclosing frame, matching
    /// ctx_EnclosedFrame's lexical link. Function/proc argument and module
    /// policy will be layered on this primitive instead of inventing a second
    /// scope model.
    Frame pushEnclosed(Frame enclosed) {
        auto frame = new Frame(enclosed);
        frameStack ~= frame;
        currentFrame = frame;
        return frame;
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

    private Cell lookupLocalOrGlobal(string name, ref Frame foundFrame) {
        auto cell = lookupFrame(currentFrame, name, false, foundFrame);
        if (cell !is null) {
            return cell;
        }

        if (currentFrame !is globalFrame) {
            return lookupFrame(globalFrame, name, false, foundFrame);
        }

        return null;
    }

    private static void requireWritable(string name, Cell cell) {
        if (cell.readOnly) {
            throw new YshError(format("Can't assign to readonly value '%s'", name));
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
