module yshd.glob;

import std.path : baseName;
import std.string : toStringz;
import std.conv : to;
import yshd.libc_patterns;
import yshd.state : Memory;
import yshd.value : ValueKind, YshDict, StructuredError;

/// osh/glob_.py:Globber.DoShellGlob / DoLibcGlob. libc owns filesystem glob
/// traversal; D owns option/global filtering and structured error conversion.
string[] globPaths(string pattern, Memory mem, bool shellFilters = true) {
    string[] ignored;
    bool hasIgnore;
    if (shellFilters) {
        auto cell = mem.globalFrame.cells.get("GLOBIGNORE", null);
        if (cell !is null && cell.value.kind == ValueKind.stringValue && cell.value.stringValue.length) {
            hasIgnore = true;
            string part;
            bool bracket;
            foreach (ch; cell.value.stringValue) {
                if (ch == '[') bracket = true;
                else if (ch == ']') bracket = false;
                if (ch == ':' && !bracket) {
                    if (part.length) ignored ~= part;
                    part = "";
                } else part ~= ch;
            }
            if (part.length) ignored ~= part;
        }
    }
    int flags;
    if (shellFilters && (hasIgnore || mem.options.get("dotglob"))) {
        static if (__traits(compiles, GLOB_PERIOD)) flags |= GLOB_PERIOD;
    }
    glob_t paths;
    auto status = glob(pattern.toStringz(), flags, null, &paths);
    scope (exit) globfree(&paths);
    if (status == GLOB_NOMATCH) return [];
    if (status != 0) {
        auto message = status == GLOB_NOSPACE ? "GLOB_NOSPACE" :
            status == GLOB_ABORTED ? "GLOB_ABORTED" : "Unknown error from glob()";
        throw new StructuredError(4, message, new YshDict());
    }
    string[] result;
    foreach (index; 0 .. paths.gl_pathc) {
        auto path = to!string(paths.gl_pathv[index]);
        if (shellFilters) {
            if (hasIgnore) {
                if (baseName(path) == "." || baseName(path) == "..") continue;
                bool skip;
                foreach (ignore; ignored) if (fnmatch(ignore.toStringz(), path.toStringz(), 0) == 0) { skip = true; break; }
                if (skip) continue;
            } else {
                if (mem.options.get("no_dash_glob") && path.length && path[0] == '-') continue;
                if (mem.options.get("globskipdots") && (path == "." || path == "..")) continue;
            }
        }
        result ~= path;
    }
    return result;
}
