module yshd.command;

import std.format : format;

import yshd.expr : AssignmentScope, ResolvedPlace, evaluate, resolvePlace;
import yshd.state : Memory;
import yshd.value : Value, ValueKind, YshError;

/// Semantic form of command.VarDecl after parsing.
///
/// The full parser will construct this from var/const syntax. Keeping command
/// evaluation separate from parsing follows osh/cmd_eval.py:_DoVarDecl.
struct VarDecl {
    string[] names;
    bool readOnly;
    bool hasRhs;
    string rhsSource;
}

/// Semantic form of command.Mutation after parsing.
struct Mutation {
    string[] targets;
    AssignmentScope assignmentScope = AssignmentScope.local;
    string rhsSource;
}

private Value[] destructure(Value right, size_t count, string description) {
    if (count == 1) {
        return [right];
    }

    if (right.kind != ValueKind.list) {
        throw new YshError(description ~ " expected List");
    }
    if (right.listValue.length != count) {
        throw new YshError(format(
            "Got %s places on the left, but %s values on the right",
            count, right.listValue.length));
    }

    return right.listValue.items.dup;
}

/// Translate osh/cmd_eval.py:_DoVarDecl semantics.
///
/// var x, y initializes both names to null. Multiple declarations destructure
/// one List value, which is how the parsed YSH testlist reaches command
/// evaluation upstream.
void executeVarDecl(VarDecl declaration, Memory mem) {
    if (declaration.names.length == 0) {
        throw new YshError("var/const declaration needs at least one name");
    }

    if (!declaration.hasRhs) {
        foreach (name; declaration.names) {
            mem.declareLocal(name, Value.nullValue(), declaration.readOnly);
        }
        return;
    }

    auto right = evaluate(declaration.rhsSource, mem);
    auto values = destructure(
        right, declaration.names.length, "Destructuring assignment");

    foreach (index, name; declaration.names) {
        mem.declareLocal(name, values[index], declaration.readOnly);
    }
}

/// Translate the ordinary '=' branch of osh/cmd_eval.py:_DoMutation.
///
/// All places and the complete RHS value are determined before mutation starts,
/// so swaps like setvar x, y = y, x retain YSH's simultaneous-assignment
/// behavior.
void executeMutation(Mutation mutation, Memory mem) {
    if (mutation.targets.length == 0) {
        throw new YshError("mutation needs at least one target");
    }

    auto right = evaluate(mutation.rhsSource, mem);
    auto values = destructure(
        right, mutation.targets.length, "Destructuring assignment");

    // Upstream evaluates every y_lvalue before applying the first mutation.
    // This preserves index/object identity across swaps and other simultaneous
    // assignments.
    ResolvedPlace[] places;
    foreach (target; mutation.targets) {
        places ~= resolvePlace(target, mem, mutation.assignmentScope);
    }

    foreach (index, place; places) {
        place.assign(values[index]);
    }
}

unittest {
    import yshd.value : repr;

    auto mem = new Memory();

    executeVarDecl(VarDecl(["x"], false, true, "1"), mem);
    executeMutation(Mutation(["x"], AssignmentScope.local, "42"), mem);
    assert(repr(mem.get("x")) == "42");

    executeVarDecl(VarDecl(["a", "b"], false, false, ""), mem);
    assert(repr(mem.get("a")) == "null");
    assert(repr(mem.get("b")) == "null");

    executeVarDecl(VarDecl(["left", "right"], false, true, "[3, 4]"), mem);
    assert(repr(mem.get("left")) == "3");
    assert(repr(mem.get("right")) == "4");

    executeMutation(
        Mutation(["left", "right"], AssignmentScope.local, "[right, left]"),
        mem);
    assert(repr(mem.get("left")) == "4");
    assert(repr(mem.get("right")) == "3");

    executeVarDecl(VarDecl(["items"], false, true, "[1, 2, 3]"), mem);
    executeMutation(
        Mutation(["items[0]", "items[1]"], AssignmentScope.local,
            "[items[1], items[0]]"),
        mem);
    assert(repr(mem.get("items")) == "[2, 1, 3]");

    executeVarDecl(VarDecl(["record"], false, true, "{int: 42}"), mem);
    executeMutation(
        Mutation(["items[0]", "record.int"], AssignmentScope.local,
            "[record.int, items[0]]"),
        mem);
    assert(repr(mem.get("items")) == "[42, 1, 3]");
    assert(repr(evaluate("record.int", mem)) == "2");

    executeVarDecl(VarDecl(["i"], false, true, "0"), mem);
    executeVarDecl(VarDecl(["indexed"], false, true, "[10, 20]"), mem);
    executeMutation(
        Mutation(["i", "indexed[i]"], AssignmentScope.local, "[1, 99]"),
        mem);
    assert(repr(mem.get("i")) == "1");
    // The container index was resolved while i was still 0.
    assert(repr(mem.get("indexed")) == "[99, 20]");

    auto globalFrame = mem.currentFrame;
    executeVarDecl(VarDecl(["globalRecord"], false, true, "{value: 1}"), mem);
    mem.pushEnclosed(globalFrame);
    executeVarDecl(VarDecl(["globalRecord"], false, true, "{value: 2}"), mem);
    executeMutation(
        Mutation(["globalRecord.value"], AssignmentScope.global, "3"), mem);
    assert(repr(evaluate("globalRecord.value", mem)) == "2");
    mem.popFrame();
    assert(repr(evaluate("globalRecord.value", mem)) == "3");

    executeVarDecl(VarDecl(["constant"], true, true, "'fixed'"), mem);
    bool rejected;
    try {
        executeMutation(
            Mutation(["constant"], AssignmentScope.local, "'changed'"), mem);
    } catch (YshError error) {
        rejected = true;
    }
    assert(rejected);
}
