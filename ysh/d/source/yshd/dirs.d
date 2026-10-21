module yshd.dirs;

import std.conv : to;
import std.file : chdir, getcwd, FileException;
import std.format : format;
import std.path : absolutePath, buildNormalizedPath;
import std.string : indexOf, join, fromStringz, toStringz;

import yshd.state : Memory;
import yshd.value : Value, ValueKind, UsageError;

/// builtin/dirs_osh.py:DirStack always contains at least the initial directory.
class DirectoryStack {
    private string[] stack;
    this() { reset(); }
    void reset() { stack = [getcwd()]; }
    void replace(string directory) { stack[$ - 1] = directory; }
    void push(string directory) { stack ~= directory; }
    bool pop(out string directory) {
        if (stack.length <= 1) return false;
        stack.length--;
        directory = stack[$ - 1];
        return true;
    }
    string[] entries() {
        string[] result;
        foreach_reverse (directory; stack) result ~= directory;
        return result;
    }
}

string physicalDirectory(string directory) {
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    auto resolved = realpath(directory.toStringz(), null);
    if (resolved is null) return directory;
    scope (exit) free(resolved);
    return fromStringz(resolved).idup;
}

void setDirectory(Memory mem, string directory, bool exported = true) {
    mem.setGlobal("PWD", Value.str(directory));
    if (exported) mem.get("ENV").dictValue.set("PWD", Value.str(directory));
    mem.workingDirectory = directory;
}

/// Pop before chdir, including the reference's failed-chdir stack mutation.
bool popDirectory(Memory mem, string label) {
    string destination;
    if (!mem.directoryStack.pop(destination)) {
        mem.errorFile.writeln(label, ": directory stack is empty");
        return false;
    }
    try { chdir(destination); }
    catch (FileException error) { mem.errorFile.writeln(label, ": ", error.msg); return false; }
    setDirectory(mem, destination, false);
    return true;
}

private void printDirectories(Memory mem, int style, bool literal) {
    auto home = literal ? null : mem.getCell("HOME");
    string[] rendered;
    foreach (index, directory; mem.directoryStack.entries()) {
        auto text = directory;
        if (home !is null && home.value.kind == ValueKind.stringValue) {
            auto prefix = home.value.stringValue;
            if (directory == prefix || (directory.length > prefix.length &&
                    directory[0 .. prefix.length] == prefix && directory[prefix.length] == '/'))
                text = "~" ~ directory[prefix.length .. $];
        }
        if (style == 1) mem.outputFile.writeln(format("%2d  %s", index, text));
        else if (style == 2) mem.outputFile.writeln(text);
        else rendered ~= text;
    }
    if (style == 0) mem.outputFile.writeln(rendered.join(" "));
}

int runDirectoryBuiltin(string name, string[] arguments, Memory mem) {
    bool clear, numbered, perLine, literal, physical;
    size_t index;
    for (; index < arguments.length; ++index) {
        auto argument = arguments[index];
        if (argument == "--") { ++index; break; }
        if (argument.length < 2 || argument[0] != '-') break;
        foreach (flag; argument[1 .. $]) {
            if (name == "dirs") {
                switch (flag) {
                case 'c': clear = true; break;
                case 'v': numbered = true; break;
                case 'p': perLine = true; break;
                case 'l': literal = true; break;
                default: throw new UsageError("dirs: invalid flag " ~ argument);
                }
            } else if (name == "pwd" && (flag == 'P' || flag == 'L')) {
                // The current reference gives -P priority regardless of order.
                if (flag == 'P') physical = true;
            } else throw new UsageError(name ~ ": invalid flag " ~ argument);
        }
    }
    auto operands = arguments[index .. $];
    if (name == "pushd") {
        if (!operands.length) { mem.errorFile.writeln("pushd: no other directory"); return 1; }
        if (operands.length != 1) throw new UsageError("pushd: expected one directory");
        // abspath uses the process cwd, which may differ from logical pwd.
        auto destination = buildNormalizedPath(absolutePath(operands[0]));
        try { chdir(destination); }
        catch (FileException error) { mem.errorFile.writeln("pushd: ", error.msg); return 1; }
        mem.directoryStack.push(destination);
        printDirectories(mem, 0, false);
        setDirectory(mem, destination);
    } else if (name == "popd") {
        if (operands.length) throw new UsageError("popd: unexpected argument");
        if (!popDirectory(mem, name)) return 1;
        printDirectories(mem, 0, false);
    } else if (name == "dirs") {
        if (operands.length) throw new UsageError("dirs: unexpected argument");
        if (clear) mem.directoryStack.reset();
        else printDirectories(mem, numbered ? 1 : perLine ? 2 : 0, literal);
    } else {
        assert(name == "pwd");
        if (mem.options.get("strict_arg_parse") && operands.length)
            throw new UsageError("pwd: unexpected argument");
        mem.outputFile.writeln(physical ? physicalDirectory(mem.workingDirectory) : mem.workingDirectory);
    }
    return 0;
}
