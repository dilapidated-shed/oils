module yshd.hash;

import std.algorithm : sort;
import yshd.state : Memory;
import yshd.value : UsageError;

// Python 2's repr(str), as used by builtin/pure_osh.py:Hash's diagnostic.
private string commandRepr(string word) {
    import std.string : indexOf;
    auto quote = word.indexOf('\'') >= 0 && word.indexOf('"') < 0 ? '"' : '\'';
    string result = [quote];
    foreach (character; word) {
        if (character == quote || character == '\\') result ~= "\\" ~ character;
        else if (character == '\t') result ~= "\\t";
        else if (character == '\n') result ~= "\\n";
        else if (character == '\r') result ~= "\\r";
        else if (character < ' ' || character >= 0x7f) {
            result ~= "\\x";
            result ~= "0123456789abcdef"[cast(ubyte)character >> 4];
            result ~= "0123456789abcdef"[character & 15];
        } else result ~= character;
    }
    return result ~ quote;
}

int runHash(string[] words, Memory mem) {
    bool reset;
    size_t index;
    for (; index < words.length; ++index) {
        auto word = words[index];
        if (word == "--") { ++index; break; }
        if (word.length < 2 || word[0] != '-') break;
        foreach (flag; word[1 .. $]) {
            if (flag != 'r') throw new UsageError("doesn't accept flag -" ~ (flag == '0' ? 'Z' : flag));
            reset = true;
        }
    }
    auto rest = words[index .. $];
    if (reset) {
        if (rest.length) throw new UsageError("got extra arguments after -r");
        mem.searchPath.clearCache();
        return 0;
    }
    int status;
    if (rest.length) {
        foreach (name; rest) if (mem.searchPath.cachedLookup(name) is null) {
            mem.writeDiagnostic("hash: " ~ commandRepr(name) ~ " not found");
            status = 1;
        }
    } else {
        auto commands = mem.searchPath.cachedCommands();
        sort(commands);
        foreach (command; commands) mem.outputFile.writeln(command);
    }
    return status;
}
