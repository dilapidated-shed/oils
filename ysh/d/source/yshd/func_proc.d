module yshd.func_proc;

import std.format : format;

import yshd.expr : evaluate;
import yshd.program : executeProgram;
import yshd.state : Frame, Memory;
import yshd.value : Value, ValueKind, YshDict, YshError;

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

/// User function closure and argument binding translated from ysh/func_proc.py.
///
/// YSH has two typed parameter groups for funcs: positional parameters before
/// ';' and named parameters after it. Each group may end in ...rest. Defaults
/// are evaluated once at definition time and mutable List/Dict defaults are
/// rejected, matching the upstream binder.
class YshFunction {
    string name;

    FunctionParameter[] parameters;
    string restPositionalName;
    Value[] defaults;
    bool[] hasDefaults;

    FunctionParameter[] namedParameters;
    string restNamedName;
    Value[] namedDefaults;
    bool[] namedHasDefaults;

    string bodySource;
    Frame closure;

    this(string name, FunctionParameter[] parameters, string bodySource,
            Memory definitionMemory, string restPositionalName = "",
            FunctionParameter[] namedParameters = [],
            string restNamedName = "") {
        this.name = name;
        this.parameters = parameters;
        this.restPositionalName = restPositionalName;
        this.namedParameters = namedParameters;
        this.restNamedName = restNamedName;
        this.bodySource = bodySource;
        closure = definitionMemory.currentFrame;

        evaluateDefaults(parameters, definitionMemory, defaults, hasDefaults);
        evaluateDefaults(namedParameters, definitionMemory,
            namedDefaults, namedHasDefaults);
    }

    private static void evaluateDefaults(FunctionParameter[] source,
            Memory definitionMemory, ref Value[] values,
            ref bool[] present) {
        bool sawDefault;
        foreach (parameter; source) {
            if (parameter.defaultSource.length == 0) {
                if (sawDefault) {
                    throw new YshError(
                        "required parameter follows a default parameter");
                }
                values ~= Value.nullValue();
                present ~= false;
                continue;
            }

            sawDefault = true;
            auto value = evaluate(parameter.defaultSource, definitionMemory);
            if (value.kind == ValueKind.list || value.kind == ValueKind.dict) {
                throw new YshError("Default values can't be mutable");
            }
            values ~= value;
            present ~= true;
        }
    }

    private size_t positionalRequired() const {
        size_t required;
        foreach (hasDefault; hasDefaults) {
            if (!hasDefault) {
                ++required;
            }
        }
        return required;
    }

    Value invoke(Value[] arguments, YshDict namedArguments = null,
            Memory callerMemory = null) {
        auto required = positionalRequired();
        if (arguments.length < required) {
            throw new YshError(format(
                "Func '%s' requires %s positional args, got %s",
                name, required, arguments.length));
        }
        if (restPositionalName.length == 0 &&
                arguments.length > parameters.length) {
            throw new YshError(format(
                "Func '%s' takes %s positional args, got %s",
                name, parameters.length, arguments.length));
        }

        auto memory = callerMemory is null
            ? new Memory()
            : new Memory(callerMemory.outputFile, callerMemory.errorFile);
        memory.pushEnclosed(closure);
        scope (exit) memory.popFrame();

        foreach (index, parameter; parameters) {
            auto value = index < arguments.length
                ? arguments[index]
                : defaults[index];
            memory.declareLocal(parameter.name, value);
        }

        if (restPositionalName.length != 0) {
            Value[] rest;
            if (arguments.length > parameters.length) {
                rest = arguments[parameters.length .. $].dup;
            }
            memory.declareLocal(restPositionalName, Value.list(rest));
        }

        auto remainingNamed = namedArguments is null
            ? new YshDict()
            : namedArguments.shallowCopy();

        foreach (index, parameter; namedParameters) {
            auto supplied = remainingNamed.find(parameter.name);
            if (supplied !is null) {
                memory.declareLocal(parameter.name, *supplied);
                remainingNamed.erase(parameter.name);
                continue;
            }

            if (!namedHasDefaults[index]) {
                throw new YshError(format(
                    "Func '%s' wasn't passed named param '%s'",
                    name, parameter.name));
            }
            memory.declareLocal(parameter.name, namedDefaults[index]);
        }

        if (restNamedName.length != 0) {
            memory.declareLocal(restNamedName, Value.dictRef(remainingNamed));
        } else if (remainingNamed.length != 0) {
            throw new YshError(format(
                "Func '%s' takes %s named args, got %s",
                name, namedParameters.length,
                namedParameters.length + remainingNamed.length));
        }

        try {
            executeProgram(bodySource, memory);
        } catch (FunctionReturn returned) {
            return returned.value;
        }
        return Value.nullValue();
    }
}


/// User-defined proc word-argument binding from ysh/func_proc.py.
///
/// An open proc (no signature) receives its command words in ARGV. A closed
/// proc binds word parameters and an optional ...rest list. Typed, named, and
/// block proc argument groups are layered separately by the command parser.
class YshProc {
    string name;
    bool openSignature;
    FunctionParameter[] wordParameters;
    string restWordName;
    Value[] defaults;
    bool[] hasDefaults;
    string bodySource;
    Frame closure;

    this(string name, string bodySource, Memory definitionMemory,
            bool openSignature = true,
            FunctionParameter[] wordParameters = [],
            string restWordName = "") {
        this.name = name;
        this.openSignature = openSignature;
        this.wordParameters = wordParameters;
        this.restWordName = restWordName;
        this.bodySource = bodySource;
        closure = definitionMemory.currentFrame;

        if (!openSignature) {
            bool sawDefault;
            foreach (parameter; wordParameters) {
                if (parameter.defaultSource.length == 0) {
                    if (sawDefault) {
                        throw new YshError(
                            "required parameter follows a default parameter");
                    }
                    defaults ~= Value.nullValue();
                    hasDefaults ~= false;
                    continue;
                }

                sawDefault = true;
                auto value = evaluate(parameter.defaultSource, definitionMemory);
                if (value.kind == ValueKind.list ||
                        value.kind == ValueKind.dict) {
                    throw new YshError("Default values can't be mutable");
                }
                defaults ~= value;
                hasDefaults ~= true;
            }
        }
    }

    Value invoke(string[] words, Memory callerMemory = null) {
        auto memory = callerMemory is null
            ? new Memory()
            : new Memory(callerMemory.outputFile, callerMemory.errorFile);
        memory.pushEnclosed(closure);
        scope (exit) memory.popFrame();

        if (openSignature) {
            Value[] argv;
            foreach (word; words) {
                argv ~= Value.str(word);
            }
            memory.declareLocal("ARGV", Value.list(argv));
        } else {
            // Closed procs bind their word arguments and expose an empty ARGV,
            // matching the upstream distinction between closed and open procs.
            memory.declareLocal("ARGV", Value.list([]));

            foreach (index, parameter; wordParameters) {
                Value value;
                if (index < words.length) {
                    value = Value.str(words[index]);
                } else if (hasDefaults[index]) {
                    value = defaults[index];
                } else {
                    throw new YshError(format(
                        "proc '%s' wasn't passed word param '%s'",
                        name, parameter.name));
                }
                memory.declareLocal(parameter.name, value);
            }

            if (restWordName.length != 0) {
                Value[] rest;
                if (words.length > wordParameters.length) {
                    foreach (word; words[wordParameters.length .. $]) {
                        rest ~= Value.str(word);
                    }
                }
                memory.declareLocal(restWordName, Value.list(rest));
            } else if (words.length > wordParameters.length) {
                throw new YshError(format(
                    "proc '%s' takes %s words, but got %s",
                    name, wordParameters.length, words.length));
            }
        }

        try {
            executeProgram(bodySource, memory);
        } catch (FunctionReturn returned) {
            return returned.value;
        }
        return Value.integer(0);
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

    auto varargs = new YshFunction("pick", [
        FunctionParameter("first", ""),
    ], "return (rest[1])\n", memory, "rest");
    assert(varargs.invoke([
        Value.integer(0), Value.integer(10), Value.integer(20),
    ]).integerValue == 20);

    auto named = new YshFunction("named", [],
        "return (x + y)\n", memory, "", [
            FunctionParameter("x", "3"),
            FunctionParameter("y", "4"),
        ]);
    auto namedArgs = new YshDict();
    namedArgs.set("y", Value.integer(10));
    assert(named.invoke([], namedArgs).integerValue == 13);

    auto namedRest = new YshFunction("named_rest", [],
        "return (other.z)\n", memory, "", [], "other");
    auto extras = new YshDict();
    extras.set("z", Value.integer(9));
    assert(namedRest.invoke([], extras).integerValue == 9);

    auto openProc = new YshProc("open",
        "return (ARGV[1])\n", memory);
    assert(openProc.invoke(["a", "b", "c"]).stringValue == "b");

    auto closedProc = new YshProc("closed",
        "return (rest[0])\n", memory, false, [
            FunctionParameter("first", ""),
        ], "rest");
    assert(closedProc.invoke(["a", "b", "c"]).stringValue == "b");

    auto defaultProc = new YshProc("defaulted",
        "return (word)\n", memory, false, [
            FunctionParameter("word", "'fallback'"),
        ]);
    assert(defaultProc.invoke([]).stringValue == "fallback");

    bool rejectedMutableDefault;
    try {
        new YshFunction("bad", [FunctionParameter("items", "[]")], "", memory);
    } catch (YshError error) {
        rejectedMutableDefault = true;
    }
    assert(rejectedMutableDefault);
}
