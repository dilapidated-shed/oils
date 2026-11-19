module yshd.getopts;

// Literal translation of builtin/pure_osh.py:GetOpts. In particular, this
// retains its cursor and partial writes rather than adopting libc getopt.
import std.bigint : BigInt;
import std.conv : to;
import std.string : indexOf;
import yshd.state : Memory;
import yshd.value : Value, ValueKind, UsageError, InterpreterFailure, kindName;

private string argumentRepr(string word) {
    auto quote = word.indexOf('\'') >= 0 && word.indexOf('"') < 0 ? '"' : '\'';
    string result = [quote];
    foreach (character; word) {
        if (character == quote || character == '\\') {
            result ~= '\\';
            result ~= character;
        } else if (character == '\t') result ~= "\\t";
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

private struct OptionSpec {
    bool silent;
    bool[256] present;
    bool[256] argument;
}

private OptionSpec parseSpec(string text) {
    OptionSpec result;
    size_t index;
    if (text.length && text[0] == ':') { result.silent = true; ++index; }
    while (index < text.length) {
        auto flag = cast(ubyte)text[index++];
        result.present[flag] = true;
        result.argument[flag] = false;
        if (index < text.length && text[index] == ':') {
            result.argument[flag] = true;
            ++index;
        }
    }
    return result;
}

private bool integerVariable(Memory mem, string name, out BigInt result, out string error) {
    auto cell = mem.getCell(name);
    if (cell is null || cell.value.kind != ValueKind.stringValue) {
        error = "$" ~ name ~ " should be a string, got " ~
            (cell is null ? "Undef" : kindName(cell.value));
        return false;
    }
    auto original = cell.value.stringValue;
    // Python2 int(str) trims ASCII whitespace without decoding its bytes.
    bool space(char character) {
        return character == ' ' || character >= '\t' && character <= '\r';
    }
    size_t first, last = original.length;
    while (first < last && space(original[first])) ++first;
    while (last > first && space(original[last - 1])) --last;
    auto number = original[first .. last];
    bool negative;
    if (number.length && (number[0] == '+' || number[0] == '-')) {
        negative = number[0] == '-';
        number = number[1 .. $];
    }
    bool valid = number.length != 0;
    result = BigInt(0);
    foreach (character; number) {
        if (character < '0' || character > '9') { valid = false; break; }
        result = result * 10 + (character - '0');
    }
    if (!valid) {
        error = "$" ~ name ~ " doesn't look like an integer, got " ~ argumentRepr(original);
        return false;
    }
    if (negative) result = -result;
    return true;
}

private bool currentArgument(string[] argv, Memory mem, ref BigInt cachedIndex, out string current) {
    BigInt index;
    string error;
    if (!integerVariable(mem, "OPTIND", index, error)) {
        mem.writeDiagnostic(error);
        return false;
    }
    // -1 is GetOptsState's invalid sentinel, even when explicitly assigned.
    if (index == -1) return false;
    cachedIndex = index;
    if (index < 1 || index > argv.length) return false;
    current = argv[to!size_t(index - 1)];
    return true;
}

private void incrementIndex(Memory mem, BigInt cachedIndex) {
    mem.setShellVar("OPTIND", Value.str(to!string(cachedIndex + 1)));
    // A failed readonly write must leave the old byte cursor in place.
    mem.getoptsFlagPosition = 1;
}

private void failOption(Memory mem, bool silent, BigInt opterr, string error, string flag = "") {
    mem.setShellVar("OPTARG", Value.str(silent ? flag : ""));
    if (!silent && opterr != 0 && error.length) mem.writeDiagnostic(error);
}

private int oneIteration(OptionSpec spec, string[] argv, Memory mem, BigInt opterr, out string selected) {
    BigInt cachedIndex = -1;
    string current;
    selected = "?";
    if (!currentArgument(argv, mem, cachedIndex, current) ||
            !current.length || current[0] != '-' || current == "-") {
        failOption(mem, spec.silent, opterr, "");
        return 1;
    }
    if (current == "--") {
        incrementIndex(mem, cachedIndex);
        return 1;
    }

    auto position = mem.getoptsFlagPosition;
    // The retained Python implementation raises IndexError here if a caller
    // replaces a cluster with a shorter word. This uncaught interpreter error
    // bypasses EXIT traps, unlike an ordinary fatal shell runtime error.
    if (position >= current.length) throw new InterpreterFailure("getopts: option byte index out of range");
    auto flag = current[position .. position + 1];
    bool moreCharacters = position < current.length - 1;
    if (moreCharacters) ++mem.getoptsFlagPosition;
    else incrementIndex(mem, cachedIndex);

    auto byteIndex = cast(ubyte)flag[0];
    if (!spec.present[byteIndex]) {
        failOption(mem, spec.silent, opterr, "getopts: invalid flag -" ~ flag, flag);
        return 0;
    }
    if (spec.argument[byteIndex]) {
        string argument;
        if (moreCharacters) argument = current[mem.getoptsFlagPosition .. $];
        else if (!currentArgument(argv, mem, cachedIndex, argument)) {
            failOption(mem, spec.silent, opterr, "getopts: flag -" ~ flag ~ " requires an argument", flag);
            selected = spec.silent ? ":" : "?";
            return 0;
        }
        incrementIndex(mem, cachedIndex);
        mem.setShellVar("OPTARG", Value.str(argument));
    } else mem.setShellVar("OPTARG", Value.str(""));
    selected = flag;
    return 0;
}

private bool validName(string name) {
    // The retained minimal reference's match.IsValidVarName Python fallback
    // uses a '$' anchor, which accepts one final LF. Keep the stored key intact.
    if (name.length && name[$ - 1] == '\n') name = name[0 .. $ - 1];
    if (!name.length || name[0] >= '0' && name[0] <= '9') return false;
    foreach (character; name)
        if (!(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
                character >= '0' && character <= '9' || character == '_')) return false;
    return true;
}

// Command dispatch performs ordinary argument evaluation first. Like the
// retained builtin, this accepts only argv and ignores typed args and blocks.
int runGetOpts(string[] words, Memory mem) {
    if (!words.length) throw new UsageError("requires an argspec");
    if (words.length < 2) throw new UsageError("requires the name of a variable to set");
    BigInt opterr;
    string ignored;
    if (!integerVariable(mem, "OPTERR", opterr, ignored)) opterr = 1;
    auto spec = parseSpec(words[0]);
    auto argv = words.length == 2 ? mem.shellArguments : words[2 .. $];
    string selected;
    auto status = oneIteration(spec, argv, mem, opterr, selected);
    // Deliberately validate after OPTIND, OPTARG and cursor side effects.
    if (!validName(words[1]))
        throw new UsageError("got invalid variable name " ~ argumentRepr(words[1]));
    mem.setShellVar(words[1], Value.str(selected));
    return status;
}
