module yshd.umask;

// builtin/umask_osh.py and frontend/flag_def.py:UMASK_SPEC.
import core.sys.posix.sys.stat : umask;
import core.sys.posix.sys.types : mode_t;
import std.bigint : BigInt, toDecimalString;
import std.conv : octal, to;
import std.format : format;
import std.string : indexOf, split, strip;
import yshd.state : Memory;
import yshd.value : FatalRuntimeError, UsageError;

private bool octalMode(string word, out int result) {
    auto number = strip(word, " \t\r\n\v\f");
    if (!number.length) return false;
    bool negative;
    if (number[0] == '+' || number[0] == '-') {
        negative = number[0] == '-';
        number = number[1 .. $];
    }
    if (number.length >= 2 && number[0] == '0' && (number[1] == 'o' || number[1] == 'O'))
        number = number[2 .. $];
    if (!number.length) return false;
    foreach (character; number) if (character < '0' || character > '7') return false;
    BigInt value;
    foreach (character; number) value = value * 8 + (character - '0');
    if (negative) value = -value;
    // The original POSIX bridge accepts a signed C int before the kernel
    // truncates to permission bits. Overflow is fatal, not a wrapped mode.
    if (value < BigInt(int.min) || value > BigInt(int.max))
        throw new FatalRuntimeError("umask: mode outside signed C int range");
    result = to!int(toDecimalString(value));
    return true;
}

private uint selectedBits(uint who, uint permissions) {
    uint result;
    if (who & 4) result |= permissions << 6;
    if (who & 2) result |= permissions << 3;
    if (who & 1) result |= permissions;
    return result;
}

private bool symbolicMode(string word, uint initialMask, out uint result, out string warning) {
    result = initialMask;
    if (!word.length) {
        warning = "oils warning: symbolic mode operator cannot be empty";
        return false;
    }
    foreach (clause; word.split(",")) {
        if (!clause.length) {
            warning = "oils warning: symbolic mode operator cannot be empty";
            return false;
        }
        size_t position;
        uint who;
        while (position < clause.length && "ugoa".indexOf(clause[position]) >= 0) {
            switch (clause[position++]) {
            case 'u': who |= 4; break;
            case 'g': who |= 2; break;
            case 'o': who |= 1; break;
            case 'a': who |= 7; break;
            default: assert(0);
            }
        }
        if (!who) who = 7;
        if (position == clause.length) {
            warning = "oils warning: actionlist is required";
            return false;
        }
        while (position < clause.length) {
            auto operation = clause[position];
            if ("+-=".indexOf(operation) < 0) {
                warning = "oils warning: expected one of `+-=` at start of action instead of `" ~
                    clause[position .. position + 1] ~ "`";
                return false;
            }
            ++position;
            uint permissions;
            while (position < clause.length && "+-=".indexOf(clause[position]) < 0) {
                auto character = clause[position];
                switch (character) {
                case 'r': permissions |= 4; break;
                case 'w': permissions |= 2; break;
                case 'x': permissions |= 1; break;
                case 'X': if (initialMask & octal!111) permissions |= 1; break;
                case 's': case 't': break;
                case 'u': permissions |= (~initialMask >> 6) & 7; break;
                case 'g': permissions |= (~initialMask >> 3) & 7; break;
                case 'o': permissions |= ~initialMask & 7; break;
                default:
                    // An unrecognized first permission starts the next
                    // attempted action in the retained parser.
                    warning = (permissions == 0 && position && "+-=".indexOf(clause[position - 1]) >= 0)
                        ? "oils warning: expected one of `+-=` at start of action instead of `" ~
                            clause[position .. position + 1] ~ "`"
                        : "oil warning: expected one of `rwxXstugo` in permlist instead of `" ~
                            clause[position .. position + 1] ~ "`";
                    return false;
                }
                ++position;
            }
            if (operation == '=') result |= selectedBits(who, 7);
            auto bits = selectedBits(who, permissions);
            if (operation == '-') result |= bits;
            else result &= octal!777 - bits;
        }
    }
    return true;
}

int runUmask(string[] words, Memory mem) {
    size_t position;
    for (; position < words.length; ++position) {
        auto word = words[position];
        if (word == "--") { ++position; break; }
        if (word.length < 2 || word[0] != '-') break;
        foreach (character; word[1 .. $]) {
            if (character != 'p' && character != 'S')
                throw new UsageError("umask: doesn't accept flag -" ~ (character == '0' ? "Z" : to!string(character)));
        }
    }
    if (position == words.length) {
        auto previous = umask(0);
        umask(previous);
        // Parsed -p/-S are deliberately unused by the retained reference.
        mem.outputFile.writeln(format("0%03o", previous));
        return 0;
    }
    auto operand = words[position++];
    if (position != words.length) throw new UsageError("umask: got extra argument");
    int numeric;
    if (octalMode(operand, numeric) && numeric != -1) {
        umask(cast(mode_t)numeric);
        return 0;
    }
    auto initialMask = umask(0);
    uint nextMask;
    string warning;
    if (!symbolicMode(operand, initialMask, nextMask, warning)) {
        // The original parser writes its warning before restoring the mask.
        mem.errorFile.writeln(warning);
        mem.errorFile.flush();
        umask(initialMask);
        return 1;
    }
    umask(cast(mode_t)nextMask);
    return 0;
}

unittest {
    int number;
    assert(octalMode(" +0O022 \t", number) && number == octal!22);
    assert(octalMode("-20000000000", number) && number == int.min);
    assert(octalMode("17777777777", number) && number == int.max);
    foreach (text; ["", " ", "0o", "0_22", "022L", "089", "0x22"])
        assert(!octalMode(text, number), text);
    foreach (text; ["20000000000", "-20000000001"]) {
        bool failed;
        try { octalMode(text, number); }
        catch (FatalRuntimeError error) { failed = true; }
        assert(failed, text);
    }
    uint mask;
    string warning;
    assert(symbolicMode("a=,a=u", octal!124, mask, warning) && mask == octal!111);
    assert(symbolicMode("a=X", octal!124, mask, warning) && mask == octal!666);
    assert(symbolicMode("a=X", octal!246, mask, warning) && mask == octal!777);
    assert(symbolicMode("u+r+w+x", octal!124, mask, warning) && mask == octal!24);
    assert(symbolicMode("u=r,g=w,o=x", 0, mask, warning) && mask == octal!356);
    assert(symbolicMode("u=,g+,o-", octal!137, mask, warning) && mask == octal!737);
    foreach (text; ["", "u+r,,u-r", "u+r,", ",u+r", "u+r,,", "u", "b=rwx", "u+r,q"])
        assert(!symbolicMode(text, octal!124, mask, warning), text);
}
