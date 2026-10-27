module yshd.command_lookup;

import std.string : split;
import yshd.state : Memory;
import yshd.value : ValueKind;

// Names and precedence from frontend/builtin_def.py and meta_oils._ResolveName.
// Recognition is distinct from implementation: an untranslated builtin must
// never fall through to a same-named host executable.
enum BuiltinKind { none, normal, special, assignment, privateBuiltin }

BuiltinKind builtinKind(string name) {
    foreach (candidate; ": . exec eval set shift times trap unset".split())
        if (name == candidate) return BuiltinKind.special;
    foreach (candidate; "readonly local declare typeset export".split())
        if (name == candidate) return BuiltinKind.assignment;
    foreach (candidate; ("true false try assert break continue return exit " ~
        "read echo printf mapfile readarray cd chdir pushd popd dirs pwd source " ~
        "umask ulimit wait jobs fg bg kill shopt complete compgen compopt compadjust compexport " ~
        "getopts builtin command type hash help history fc alias unalias bind append write json json8 pp " ~
        "hay haynode use error failed fork forkwait redir fopen shvar ctx invoke runproc boolstatus " ~
        "test [ push-registers source-guard is-main").split())
        if (name == candidate) return BuiltinKind.normal;
    foreach (candidate; "cat rm sleep".split())
        if (name == candidate) return BuiltinKind.privateBuiltin;
    return BuiltinKind.none;
}

bool hasProcedure(string name, Memory mem) {
    auto cell = mem.getCell(name);
    if (cell is null) return false;
    auto value = cell.value;
    if (value.kind == ValueKind.procValue || value.kind == ValueKind.builtinProcValue) return true;
    if (value.kind != ValueKind.objectValue || value.objectValue.prototype is null) return false;
    return value.objectValue.prototype.find("__invoke__") !is null;
}

struct CommandResolution {
    string name, kind, detail;
}

string[] executablePaths(string name, string path, bool all) {
    import core.sys.posix.unistd : access, X_OK;
    import std.file : isDir;
    import std.string : indexOf, toStringz;
    if (!name.length) return [];
    string[] candidates;
    if (name.indexOf('/') >= 0) candidates = [name];
    else foreach (directory; path.split(":"))
        candidates ~= directory.length ? directory ~ "/" ~ name : name;
    string[] result;
    foreach (candidate; candidates) {
        if (access(toStringz(candidate), X_OK) != 0) continue;
        try { if (isDir(candidate)) continue; }
        catch (Exception error) { continue; }
        result ~= candidate;
        if (!all) break;
    }
    return result;
}

CommandResolution[] resolveCommand(string name, Memory mem, bool all,
        bool includeProcedures = true, bool includePrivate = false) {
    CommandResolution[] result;
    if (auto expansion = name in mem.aliases) result ~= CommandResolution(name, "alias", *expansion);
    foreach (keyword; ("if then else elif fi for while until do done case esac in function select time " ~
            "{ } [[ ]] ! var const setvar setglobal proc func typed call break continue return").split()) {
        if (name == keyword) { result ~= CommandResolution(name, "keyword", ""); break; }
    }
    auto builtin = builtinKind(name);
    if (builtin == BuiltinKind.special) result ~= CommandResolution(name, "builtin", "special");
    if (includeProcedures) {
        if (hasProcedure(name, mem)) {
            auto value = mem.getCell(name).value;
            result ~= CommandResolution(name, "proc", value.kind == ValueKind.objectValue ? "invokable" : "");
        }
        if (mem.builtins.shellFunctions.find(name) !is null) result ~= CommandResolution(name, "function", "");
    }
    if (builtin == BuiltinKind.normal || builtin == BuiltinKind.assignment)
        result ~= CommandResolution(name, "builtin", builtin == BuiltinKind.assignment ? "special" : "");
    foreach (path; executablePaths(name, mem.getEnv("PATH"), all)) result ~= CommandResolution(name, "file", path);
    if (includePrivate && builtin == BuiltinKind.privateBuiltin)
        result ~= CommandResolution(name, "builtin", "private");
    return result;
}

void printResolution(CommandResolution resolution, Memory mem) {
    with (resolution) {
        if (kind == "alias") mem.outputFile.writeln(name, " is an alias for \"", detail, "\"");
        else if (kind == "keyword") mem.outputFile.writeln(name, " is a shell keyword");
        else if (kind == "builtin") mem.outputFile.writeln(name, " is a shell builtin");
        else if (kind == "file") mem.outputFile.writeln(name, " is ", detail);
        else mem.outputFile.writeln(name, " is a ", kind);
    }
}

unittest {
    assert(builtinKind("eval") == BuiltinKind.special);
    assert(builtinKind("readonly") == BuiltinKind.assignment);
    assert(builtinKind("echo") == BuiltinKind.normal);
    assert(builtinKind("cat") == BuiltinKind.privateBuiltin);
    assert(builtinKind("not-a-builtin") == BuiltinKind.none);
    auto mem = new Memory();
    mem.aliases["echo"] = "write";
    auto resolutions = resolveCommand("echo", mem, false);
    assert(resolutions[0].kind == "alias");
    assert(resolutions[1].kind == "builtin");
    assert(!executablePaths("", "/usr/bin", false).length);
}
