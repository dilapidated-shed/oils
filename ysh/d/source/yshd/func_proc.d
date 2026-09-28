module yshd.func_proc;

import std.algorithm : canFind;
import std.format : format;

import yshd.expr : evaluate;
import yshd.program : executeProgram;
import yshd.state : Frame, Memory;
import yshd.value : Value, ValueKind, YshError;

struct FunctionParameter {
    string name;
    string defaultSource;
}

/// Return control flow is separate from ordinary YSH errors, matching the
/// distinction between VM.ValueControlFlow and error.Expr in func_proc.py.
class FunctionReturn : Exception {
    Value value;

    this(Value value) {
        super("YSH function returned");
        this.value = value;
    }
}

/// User function closure and positional argument binding, translated from
/// ysh/func_proc.py. The first command-language slice supports ordinary
/// positional parameters, definition-time immutable defaults, lexical capture,
/// and `return (expr)`. Named/variadic parameters and the full command body
/// evaluator remain separate translation work.
class YshFunction {
    string name;
    FunctionParameter[] parameters;
    Value[] defaults;
    bool[] hasDefaults;
    string bodySource;
    Frame closure;

    this(string name, FunctionParameter[] parameters, string bodySource,
            Memory definitionMemory) {
        this.name = name;
        this.parameters = parameters;
        this.bodySource = bodySource;
        closure = definitionMemory.currentFrame;
        foreach (parameter; parameters) {
            if (parameter.defaultSource.length == 0) {
                if (hasDefaults.canFind(true)) {
                    throw new YshError("required parameter follows a default parameter");
                }
                defaults ~= Value.nullValue();
                hasDefaults ~= false;
                continue;
            }
            auto value = evaluate(parameter.defaultSource, definitionMemory);
            if (value.kind == ValueKind.list || value.kind == ValueKind.dict) {
                throw new YshError("Default values can't be mutable");
            }
            defaults ~= value;
            hasDefaults ~= true;
        }
    }

    Value invoke(Value[] arguments) {
        size_t required;
        foreach (hasDefault; hasDefaults) {
            if (!hasDefault) {
                ++required;
            }
        }
        if (arguments.length < required) {
            throw new YshError(format("Func '%s' requires %s positional args, got %s",
                name, required, arguments.length));
        }
        if (arguments.length > parameters.length) {
            throw new YshError(format("Func '%s' takes %s positional args, got %s",
                name, parameters.length, arguments.length));
        }

        auto memory = new Memory();
        memory.pushEnclosed(closure);
        scope (exit) memory.popFrame();

        foreach (index, parameter; parameters) {
            auto value = index < arguments.length
                ? arguments[index]
                : defaults[index];
            memory.declareLocal(parameter.name, value);
        }

        try {
            executeProgram(bodySource, memory);
        } catch (FunctionReturn returned) {
            return returned.value;
        }
        return Value.nullValue();
    }
}

unittest {
    auto memory = new Memory();
    memory.declareLocal("captured", Value.integer(40));
    auto userFunction = new YshFunction("add", [
        FunctionParameter("amount", "2"),
    ], "return (captured + amount)\n", memory);

    assert(userFunction.invoke([]).integerValue == 42);
    assert(userFunction.invoke([Value.integer(3)]).integerValue == 43);

    bool rejectedMutableDefault;
    try {
        new YshFunction("bad", [FunctionParameter("items", "[]")], "", memory);
    } catch (YshError error) {
        rejectedMutableDefault = true;
    }
    assert(rejectedMutableDefault);
}
