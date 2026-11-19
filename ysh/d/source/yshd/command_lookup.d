module yshd.command_lookup;

import std.string : split;
import yshd.state : Memory;
import yshd.value : ValueKind;

private void checkPath(string path) {
    import std.string : indexOf;
    import yshd.value : InterpreterFailure;
    if (path.indexOf('\0') >= 0)
        throw new InterpreterFailure("filesystem pathname contains NUL");
}

// core/executor.py:LookupExecutable uses existence for an explicit pathname,
// but a regular executable file for a name searched through PATH.
private bool pathExists(string path) {
    import core.sys.posix.sys.stat : stat_t, stat;
    import std.string : toStringz;
    stat_t information;
    checkPath(path);
    return stat(path.toStringz(), &information) == 0;
}

private bool regularFile(string path, bool executable) {
    import core.sys.posix.sys.stat : stat_t, stat, S_ISREG;
    import core.sys.posix.unistd : access, X_OK;
    import std.string : toStringz;
    stat_t information;
    checkPath(path);
    return (!executable || access(path.toStringz(), X_OK) == 0) &&
        stat(path.toStringz(), &information) == 0 && S_ISREG(information.st_mode);
}

private string pathJoin(string directory, string name) {
    return !directory.length ? name :
        directory[$ - 1] == '/' ? directory ~ name : directory ~ "/" ~ name;
}

enum defaultCommandPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

string lookupExecutable(string name, string[] directories, bool execRequired = true) {
    import std.string : indexOf;
    if (!name.length) return null;
    if (name.indexOf('/') >= 0) return pathExists(name) ? name : null;
    foreach (directory; directories) {
        auto candidate = pathJoin(directory, name);
        if (regularFile(candidate, execRequired)) return candidate;
    }
    return null;
}

/// One interpreter owns one cache. Lexical frames and PATH changes do not
/// replace it; OS process isolation naturally gives forked shells a copy.
class SearchPath {
    private Memory memory;
    private string[string] cache;

    this(Memory memory) { this.memory = memory; }

    private string[] directories() {
        bool defined;
        auto path = memory.configuredPath(&defined);
        return defined ? (path.length ? path.split(":") : [""]) : [];
    }

    string lookupOne(string name, bool execRequired = true) {
        return lookupExecutable(name, directories(), execRequired);
    }

    string[] lookupReflect(string name, bool all) {
        import std.string : indexOf;
        if (!name.length) return [];
        if (name.indexOf('/') >= 0) return regularFile(name, true) ? [name] : [];
        string[] result;
        foreach (directory; directories()) {
            auto candidate = pathJoin(directory, name);
            if (!regularFile(candidate, true)) continue;
            result ~= candidate;
            if (!all) break;
        }
        return result;
    }

    string cachedLookup(string name) {
        if (auto found = name in cache) return *found;
        auto path = lookupOne(name);
        if (path !is null) cache[name] = path;
        return path;
    }

    // Expanded-argv pipeline producers will immediately exec in a child.
    // They inherit existing cache hits, but their new entries cannot survive
    // in the parent's interpreter state.
    string lookupForSubprogram(string name) {
        if (auto found = name in cache) return *found;
        return lookupOne(name);
    }

    void maybeRemoveEntry(string name) { cache.remove(name); }
    void clearCache() { cache = null; }
    string[] cachedCommands() {
        string[] result;
        foreach (path; cache) result ~= path;
        return result;
    }
}

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
    import std.string : indexOf, toStringz;
    if (!name.length) return [];
    string[] candidates;
    if (name.indexOf('/') >= 0) candidates = [name];
    else foreach (directory; path.length ? path.split(":") : [""])
        candidates ~= pathJoin(directory, name);
    string[] result;
    foreach (candidate; candidates) {
        if (!regularFile(candidate, true)) continue;
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
    foreach (path; mem.searchPath.lookupReflect(name, all)) result ~= CommandResolution(name, "file", path);
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
