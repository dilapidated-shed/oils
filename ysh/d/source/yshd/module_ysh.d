module yshd.module_ysh;

import std.file : FileException, read;
import std.path : baseName, stripExtension;
import std.string : startsWith, toStringz;
import core.stdc.stdlib : free;
import core.sys.posix.stdlib : realpath;
import std.conv : to;

import yshd.expr : EvaluatedArguments;
import yshd.func_proc : YshBuiltinProc, ProcReturn, invokeProcedure;
import yshd.program : executeProgram;
import yshd.resources : standardLibrarySource;
import yshd.state : Memory, Frame, ReturnMode;
import yshd.value : Value, ValueKind, YshDict, YshObject, UsageError, YshTypeError;

/// builtin/module_ysh.py:ModuleInvoke forwards words and typed arguments
/// without binding the module as a user proc's self argument.
class ModuleInvoke : YshBuiltinProc {
    override void invoke(string[] words, Memory mem,
            EvaluatedArguments arguments, Value self) {
        if (words.length == 0) throw new UsageError("module must be invoked with a proc name argument");
        if (self.kind != ValueKind.objectValue) throw new UsageError("module-invoke requires an Obj");
        auto value = self.objectValue.properties.find(words[0]);
        if (value !is null) {
            // A nested invokable Obj must use a user Proc, as in the reference.
            if (value.kind == ValueKind.objectValue && value.objectValue.prototype !is null) {
                auto method = value.objectValue.prototype.find("__invoke__");
                if (method !is null && method.kind != ValueKind.procValue)
                    throw new YshTypeError("module member __invoke__ should be a user-defined Proc");
            }
            if ((value.kind == ValueKind.procValue || value.kind == ValueKind.objectValue) &&
                    invokeProcedure(*value, words[1 .. $], mem, arguments)) return;
        }
        throw new UsageError("module doesn't contain invokable " ~ words[0]);
    }
}

Value moduleInvokeValue() { return Value.builtinProc(new ModuleInvoke()); }

private int bindNames(Value object, string name, string[] picked, Memory mem) {
    mem.setGlobal(name, object);
    foreach (pick; picked) {
        auto value = object.objectValue.properties.find(pick);
        if (value is null) {
            mem.errorFile.writeln("use: module doesn't provide name '", pick, "'");
            return 1;
        }
        mem.setGlobal(pick, *value);
    }
    return 0;
}

/// core/state.py:ctx_ModuleEval exports a snapshot of provided cell values.
/// Closures still retain the real module frame, so later setglobal stays local
/// to that module and does not update an already exported scalar snapshot.
private bool exportNames(Frame frame, YshDict properties, Memory mem) {
    auto provide = frame.cells.get("__provide__");
    if (provide is null || provide.value.kind != ValueKind.list) {
        mem.errorFile.writeln("use: __provide__ should be a List");
        return false;
    }
    bool valid = true;
    foreach (item; provide.value.listValue.items) {
        if (item.kind != ValueKind.stringValue) {
            mem.errorFile.writeln("use: expected Str in __provide__ List");
            valid = false;
            continue;
        }
        auto cell = frame.cells.get(item.stringValue);
        if (cell is null) {
            mem.errorFile.writeln("use: name '", item.stringValue, "' was provided, but not defined");
            valid = false;
        } else properties.set(item.stringValue, cell.value);
    }
    return valid;
}

/// builtin/meta_oils.py:Source._Use, including cache-before-evaluation to break
/// import cycles. A failed import remains cached, matching the reference.
int useModule(string[] words, Memory mem) {
    if (words.length && words[0] == "--extern") return 0;
    if (words.length && words[0] == "--") words = words[1 .. $];
    if (!words.length || words[0].startsWith("-")) throw new UsageError("use requires a module path");
    auto path = words[0];
    string[] picked;
    if (words.length > 1) {
        switch (words[1]) {
        case "--pick":
            if (words.length == 2) throw new UsageError("use --pick expects one or more names");
            picked = words[2 .. $];
            break;
        case "--all-provided": case "--all-for-testing":
            if (words.length != 2) throw new UsageError("use: unexpected argument after flag");
            // These flags are themselves unimplemented in the reference.
            mem.outputFile.writeln(words[1] == "--all-provided"
                ? "TODO: --all-provided not implemented" : "TODO: --all-for testing not implemented");
            break;
        default: throw new UsageError("use: expected flag like --pick after module path");
        }
    }
    if (!mem.atTopLevel()) throw new UsageError("use may only be used at the top level");
    auto name = stripExtension(baseName(path));
    bool embedded = path.startsWith("///");
    string key, source;
    if (embedded) {
        key = path[3 .. $];
    } else {
        auto resolved = realpath(path.toStringz(), null);
        if (resolved is null) {
            mem.errorFile.writeln("use: couldn't find '", path, "'");
            return 1;
        }
        scope (exit) free(resolved);
        key = to!string(resolved);
    }
    auto cached = embedded ? key in mem.embeddedModules : key in mem.diskModules;
    if (cached !is null) return bindNames(*cached, name, picked, mem);
    if (embedded) {
        if (!standardLibrarySource(key, source)) {
            mem.errorFile.writeln("use: no builtin file '", key, "'");
            return 1;
        }
    } else {
        try { source = cast(string)read(key); }
        catch (FileException error) { mem.errorFile.writeln("use: ", error.msg); return 1; }
    }

    auto methods = new YshDict();
    methods.set("__invoke__", mem.get("module-invoke"));
    auto properties = new YshDict();
    auto object = Value.object(new YshObject(new YshObject(null, methods), properties));
    if (embedded) mem.embeddedModules[key] = object;
    else mem.diskModules[key] = object;
    auto frame = new Frame();
    foreach (sharedName; ["ENV", "PS4"])
        if (auto cell = mem.globalFrame.cells.get(sharedName)) frame.cells.set(sharedName, cell);
    int status;
    {
        auto previousFrame = mem.setActiveGlobalFrame(frame);
        auto previousMain = mem.isMain;
        auto previousMode = mem.returnMode;
        mem.isMain = false;
        mem.returnMode = ReturnMode.shell;
        mem.pushSourceDirectory(embedded ? "stdlib/" ~ key : path);
        scope (exit) {
            --mem.sourceDirectories.length;
            mem.isMain = previousMain;
            mem.returnMode = previousMode;
            mem.setActiveGlobalFrame(previousFrame);
            exportNames(frame, properties, mem);
        }
        try { executeProgram(source, mem); status = mem.lastStatus; }
        catch (ProcReturn returned) { status = returned.status; }
    }
    if (status) return status;
    // Export was attempted during unwinding; missing/invalid entries fail use.
    auto provide = frame.cells.get("__provide__");
    if (provide is null || provide.value.kind != ValueKind.list) return 1;
    foreach (item; provide.value.listValue.items)
        if (item.kind != ValueKind.stringValue || frame.cells.get(item.stringValue) is null) return 1;
    return bindNames(object, name, picked, mem);
}
