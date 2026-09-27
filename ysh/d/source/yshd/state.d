module yshd.state;

import std.format : format;

import yshd.value : Value, YshError;

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

    this() {
        globalFrame = new Frame();
        currentFrame = globalFrame;
        frameStack = [globalFrame];
    }

    Value get(string name) {
        Frame ignored;
        auto cell = lookupLocalOrGlobal(name, ignored);
        if (cell is null) {
            throw new YshError(format("Undefined variable '%s'", name));
        }
        return cell.value;
    }

    Cell getCell(string name) {
        Frame ignored;
        return lookupLocalOrGlobal(name, ignored);
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
