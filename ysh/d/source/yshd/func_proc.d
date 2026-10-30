module yshd.func_proc;

import std.format : format;

import yshd.expr : evaluate, EvaluatedArguments;
import yshd.program : executeProcedureBody;
import yshd.state : Frame, Memory, ReturnMode, BuiltinRegistry;
import yshd.value : Value, ValueKind, YshDict, YshError, YshTypeError;

/// value.BuiltinProc has command arguments and status, distinct from Func.
abstract class YshBuiltinProc {
    abstract void invoke(string[] words, Memory mem,
        EvaluatedArguments arguments, Value self);
}

/// Shared command dispatch for direct procs and Obj prototype __invoke__.
bool invokeProcedure(Value callable, string[] words, Memory mem,
        EvaluatedArguments arguments) {
    Value self;
    if (callable.kind == ValueKind.objectValue && callable.objectValue.prototype !is null) {
        auto method = callable.objectValue.prototype.find("__invoke__");
        if (method is null) return false;
        self = callable;
        callable = *method;
    }
    if (callable.kind == ValueKind.builtinProcValue) {
        (cast(YshBuiltinProc)callable.callableValue).invoke(words, mem, arguments, self);
        return true;
    }
    if (callable.kind != ValueKind.procValue) return false;
    auto proc = cast(YshProc)callable.callableValue;
    if (self.kind == ValueKind.objectValue) {
        if (!proc.signature.positional.length && !proc.signature.restPositional.length)
            throw new YshError("Using a proc as __invoke__ requires a self param");
        arguments.positional = [self] ~ arguments.positional;
    }
    proc.invoke(words, mem, arguments);
    return true;
}

struct FunctionParameter {
    string name;
    string defaultSource;
}

struct ProcSignature {
    FunctionParameter[] positional;
    string restPositional;
    FunctionParameter[] named;
    string restNamed;
    FunctionParameter block;
    bool hasBlock;
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

class ProcReturn : Exception {
    int status;
    this(int status) { super("YSH proc returned"); this.status = status; }
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
    bool attributeScope;
    bool multiline;
    Frame closure;
    Frame moduleFrame;
    BuiltinRegistry builtins;

    this(string name, FunctionParameter[] parameters, string bodySource,
            Memory definitionMemory, string restPositionalName = "",
            FunctionParameter[] namedParameters = [],
            string restNamedName = "", bool attributeScope = false, bool multiline = false) {
        this.name = name;
        this.parameters = parameters;
        this.restPositionalName = restPositionalName;
        this.namedParameters = namedParameters;
        this.restNamedName = restNamedName;
        this.bodySource = bodySource;
        this.attributeScope = attributeScope;
        this.multiline = multiline;
        closure = definitionMemory.currentFrame;
        moduleFrame = definitionMemory.globalFrame;
        builtins = definitionMemory.builtins;

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

        auto memory = callerMemory is null ? new Memory() : callerMemory;
        auto previousGlobal = memory.setActiveGlobalFrame(moduleFrame);
        auto previousBuiltins = memory.builtins;
        auto previousMode = memory.returnMode;
        memory.builtins = builtins;
        memory.returnMode = ReturnMode.functionValue;
        memory.pushEnclosed(closure);
        scope (exit) {
            memory.popFrame();
            memory.setActiveGlobalFrame(previousGlobal);
            memory.builtins = previousBuiltins;
            memory.returnMode = previousMode;
        }

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
            executeProcedureBody(bodySource, memory, attributeScope, multiline);
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
    bool shellCompatible;
    Frame moduleFrame;
    bool openSignature;
    FunctionParameter[] wordParameters;
    string restWordName;
    Value[] defaults;
    bool[] hasDefaults;
    string bodySource;
    bool attributeScope;
    bool multiline;
    Frame closure;
    BuiltinRegistry builtins;
    ProcSignature signature;
    Value[] positionalDefaults;
    bool[] positionalHasDefaults;
    Value[] namedDefaults;
    bool[] namedHasDefaults;
    Value blockDefault;
    bool hasBlockDefault;

    this(string name, string bodySource, Memory definitionMemory,
            bool openSignature = true,
            FunctionParameter[] wordParameters = [],
            string restWordName = "", ProcSignature signature = ProcSignature.init,
            bool shellCompatible = false, bool attributeScope = false, bool multiline = false) {
        this.name = name;
        this.shellCompatible = shellCompatible;
        moduleFrame = definitionMemory.globalFrame;
        this.openSignature = openSignature;
        this.wordParameters = wordParameters;
        this.restWordName = restWordName;
        this.bodySource = bodySource;
        this.attributeScope = attributeScope;
        this.multiline = multiline;
        this.signature = signature;
        closure = shellCompatible ? null : definitionMemory.currentFrame;
        builtins = definitionMemory.builtins;

        if (!openSignature) {
            foreach (parameter; wordParameters) {
                if (parameter.defaultSource.length == 0) {
                    defaults ~= Value.nullValue();
                    hasDefaults ~= false;
                    continue;
                }

                auto value = evaluate(parameter.defaultSource, definitionMemory);
                if (value.kind != ValueKind.stringValue)
                    throw new YshTypeError("Default val for word param must be Str");
                defaults ~= value;
                hasDefaults ~= true;
            }
            evaluateProcDefaults(signature.positional, definitionMemory,
                positionalDefaults, positionalHasDefaults);
            evaluateProcDefaults(signature.named, definitionMemory,
                namedDefaults, namedHasDefaults);
            if (signature.hasBlock && signature.block.defaultSource.length) {
                blockDefault = evaluate(signature.block.defaultSource, definitionMemory);
                hasBlockDefault = true;
                if (blockDefault.kind != ValueKind.nullValue && blockDefault.kind != ValueKind.commandValue)
                    throw new YshTypeError("Default value for block should be Command or Null");
            }
        }
    }

    private static void evaluateProcDefaults(FunctionParameter[] parameters,
            Memory mem, ref Value[] values, ref bool[] present) {
        foreach (parameter; parameters) {
            bool supplied = parameter.defaultSource.length != 0;
            auto value = supplied ? evaluate(parameter.defaultSource, mem) : Value.nullValue();
            if (value.kind == ValueKind.list || value.kind == ValueKind.dict)
                throw new YshError("Default values can't be mutable");
            values ~= value;
            present ~= supplied;
        }
    }

    Value invoke(string[] words, Memory callerMemory = null,
            EvaluatedArguments arguments = EvaluatedArguments.init) {
        if (shellCompatible) {
            if (arguments.positional.length || (arguments.named !is null && arguments.named.length) || arguments.hasBlock)
                throw new YshTypeError("Shell functions do not accept typed arguments");
            return invokeShell(words, callerMemory is null ? new Memory() : callerMemory);
        }
        auto memory = callerMemory is null ? new Memory() : callerMemory;
        auto previousGlobal = memory.setActiveGlobalFrame(moduleFrame);
        auto previousBuiltins = memory.builtins;
        auto previousMode = memory.returnMode;
        import yshd.options : ShellOptions;
        auto scopeOptions = [ShellOptions.number("dynamic_scope")];
        memory.options.push(scopeOptions, false);
        scope (exit) memory.options.pop(scopeOptions);
        memory.builtins = builtins;
        memory.returnMode = ReturnMode.procValue;
        memory.pushEnclosed(closure);
        scope (exit) {
            memory.popFrame();
            memory.setActiveGlobalFrame(previousGlobal);
            memory.builtins = previousBuiltins;
            memory.returnMode = previousMode;
        }

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

            foreach (index, parameter; signature.positional) {
                if (index >= arguments.positional.length && !positionalHasDefaults[index])
                    throw new YshError(format("%s wasn't passed typed param %s", name, parameter.name));
                memory.declareLocal(parameter.name, index < arguments.positional.length
                    ? arguments.positional[index] : positionalDefaults[index]);
            }
            if (signature.restPositional.length)
                memory.declareLocal(signature.restPositional, Value.list(arguments.positional.length > signature.positional.length
                    ? arguments.positional[signature.positional.length .. $].dup : []));
            else if (arguments.positional.length > signature.positional.length)
                throw new YshError(format("Proc %s takes %s typed args, but got %s",
                    name, signature.positional.length, arguments.positional.length));

            auto remaining = arguments.named is null ? new YshDict() : arguments.named.shallowCopy();
            foreach (index, parameter; signature.named) {
                auto supplied = remaining.find(parameter.name);
                if (supplied is null && !namedHasDefaults[index])
                    throw new YshError(format("%s wasn't passed named param %s", name, parameter.name));
                memory.declareLocal(parameter.name, supplied !is null ? *supplied : namedDefaults[index]);
                remaining.erase(parameter.name);
            }
            if (signature.restNamed.length)
                memory.declareLocal(signature.restNamed, Value.dictRef(remaining));
            // The inherited _BindNamed compares the remaining count with the
            // declared count after erasing bound keys. Preserve that behavior.
            else if (remaining.length > signature.named.length)
                throw new YshError(format("Proc %s takes %s named args, but got %s",
                    name, signature.named.length, remaining.length));

            if (signature.hasBlock) {
                if (!arguments.hasBlock && !hasBlockDefault)
                    throw new YshError(format("%s wasn't passed block param %s", name, signature.block.name));
                memory.declareLocal(signature.block.name, arguments.hasBlock ? arguments.block : blockDefault);
            } else if (arguments.hasBlock)
                throw new YshError(format("Proc %s doesn't accept a block argument", name));
        }

        try {
            executeProcedureBody(bodySource, memory, attributeScope, multiline);
        } catch (ProcReturn returned) {
            memory.lastStatus = returned.status;
            return Value.integer(returned.status);
        }
        return Value.integer(memory.lastStatus);
    }

    private Value invokeShell(string[] words, Memory memory) {
        assert(memory !is null);
        auto previousGlobal = memory.setActiveGlobalFrame(moduleFrame);
        auto previousBuiltins = memory.builtins;
        auto previousArguments = memory.shellArguments;
        auto previousMode = memory.returnMode;
        memory.shellArguments = words;
        memory.builtins = builtins;
        memory.returnMode = ReturnMode.procValue;
        import yshd.options : ShellOptions;
        auto scopeOptions = [ShellOptions.number("dynamic_scope")];
        memory.options.push(scopeOptions, memory.options.get("dynamic_scope"));
        scope (exit) memory.options.pop(scopeOptions);
        memory.pushEnclosed(null);
        scope (exit) {
            memory.popFrame();
            memory.setActiveGlobalFrame(previousGlobal);
            memory.builtins = previousBuiltins;
            memory.shellArguments = previousArguments;
            memory.returnMode = previousMode;
        }
        try { executeProcedureBody(bodySource, memory, attributeScope, multiline); }
        catch (ProcReturn returned) { memory.lastStatus = returned.status; }
        return Value.integer(memory.lastStatus);
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
        "assert [ARGV[1] === 'b']; return 42\n", memory);
    assert(openProc.invoke(["a", "b", "c"], memory).integerValue == 42);
    assert(memory.lastStatus == 42);

    auto closedProc = new YshProc("closed",
        "assert [rest[0] === 'b']; return 23\n", memory, false, [
            FunctionParameter("first", ""),
        ], "rest");
    assert(closedProc.invoke(["a", "b", "c"]).integerValue == 23);

    auto defaultProc = new YshProc("defaulted",
        "assert [word === 'fallback']; return 0\n", memory, false, [
            FunctionParameter("word", "'fallback'"),
        ]);
    assert(defaultProc.invoke([]).integerValue == 0);

    bool rejectedMutableDefault;
    try {
        new YshFunction("bad", [FunctionParameter("items", "[]")], "", memory);
    } catch (YshError error) {
        rejectedMutableDefault = true;
    }
    assert(rejectedMutableDefault);
}
