module yshd.eval_scope;

import yshd.state : Memory;
import yshd.value : Value, ValueKind, YshDict, YshTypeError;

struct EvalOptions {
    bool changeZero;
    string dollarZero;
    bool changeArguments;
    string[] arguments;
    YshDict variables;
    bool inCapturedFrame;
    bool toDict;
}

EvalOptions parseEvalOptions(YshDict named, bool command) {
    EvalOptions options;
    if (named is null) return options;
    foreach (name, value; named) {
        switch (name) {
        case "dollar0":
            if (value.kind != ValueKind.stringValue) throw new YshTypeError("dollar0 should be Str");
            options.changeZero = true;
            options.dollarZero = value.stringValue;
            break;
        case "pos_args":
            if (value.kind != ValueKind.list) throw new YshTypeError("pos_args should be List");
            options.changeArguments = true;
            foreach (argument; value.listValue.items) {
                if (argument.kind != ValueKind.stringValue) throw new YshTypeError("Expected pos_args to be a List of Strs");
                options.arguments ~= argument.stringValue;
            }
            break;
        case "vars":
            if (value.kind != ValueKind.dict) throw new YshTypeError("vars should be Dict");
            options.variables = value.dictValue;
            break;
        case "in_captured_frame": case "to_dict":
            if (!command) throw new YshTypeError("Unexpected named argument " ~ name);
            if (value.kind != ValueKind.boolean) throw new YshTypeError(name ~ " should be Bool");
            if (name == "to_dict") options.toDict = value.booleanValue;
            else options.inCapturedFrame = value.booleanValue;
            break;
        default: throw new YshTypeError("Unexpected named argument " ~ name);
        }
    }
    return options;
}

/// core/state.py:ctx_Eval runs inside the selected lexical frame. Variables
/// use LocalOnly lookup (including __E__), and restore before frame capture.
Value withEvalBindings(Memory mem, EvalOptions options, Value delegate() evaluate) {
    struct Saved { string name; bool existed; Value value; }
    Saved[] saved;
    auto zero = mem.argumentZero;
    auto arguments = mem.shellArguments;
    scope (exit) {
        foreach (binding; saved) {
            if (binding.existed) mem.setVar(binding.name, binding.value);
            else mem.unsetLocal(binding.name);
        }
        if (options.changeArguments) mem.shellArguments = arguments;
        if (options.changeZero) mem.argumentZero = zero;
    }
    if (options.changeZero) mem.argumentZero = options.dollarZero;
    if (options.changeArguments) mem.shellArguments = options.arguments.dup;
    if (options.variables !is null) foreach (name, value; options.variables) {
        auto cell = mem.findLocal(name);
        auto previous = Saved(name, cell !is null, cell is null ? Value.nullValue() : cell.value);
        mem.setVar(name, value);
        saved ~= previous;
    }
    return evaluate();
}
