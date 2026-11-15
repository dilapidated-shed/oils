module yshd.shift;

// builtin/assign_osh.py:Shift delegates to core/state.py:Mem.Shift. It has
// no flag parser and ignores typed arguments after their ordinary evaluation.
import std.bigint : BigInt;
import std.string : indexOf, strip;
import yshd.state : Memory;
import yshd.value : UsageError;

private string argumentRepr(string word) {
    auto quote = word.indexOf('\'') >= 0 && word.indexOf('"') < 0 ? '"' : '\'';
    string result = [quote];
    foreach (character; word) {
        if (character == quote || character == '\\') {
            result ~= '\\';
            result ~= character;
        }
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

private BigInt shiftCount(string[] words) {
    if (words.length == 0) return BigInt(1);
    if (words.length != 1) throw new UsageError("got too many arguments");
    auto original = words[0];
    auto number = strip(original, " \t\r\n\v\f");
    bool negative;
    if (number.length && (number[0] == '+' || number[0] == '-')) {
        negative = number[0] == '-';
        number = number[1 .. $];
    }
    if (!number.length) throw new UsageError("Invalid shift argument " ~ argumentRepr(original));
    BigInt count;
    foreach (character; number) {
        if (character < '0' || character > '9')
            throw new UsageError("Invalid shift argument " ~ argumentRepr(original));
        count = count * 10 + (character - '0');
    }
    return negative ? -count : count;
}

int runShift(string[] words, Memory mem) {
    return mem.shiftShellArguments(shiftCount(words));
}

unittest {
    assert(shiftCount([]) == 1);
    assert(shiftCount([" +002 \t"]) == 2);
    assert(shiftCount(["010"]) == 10);
    assert(shiftCount(["-0"]) == 0);
    assert(shiftCount(["-999999999999999999999999999999"]) == -BigInt("999999999999999999999999999999"));
    foreach (text; ["", " ", "+", "--", "--help", "0x2", "0o2", "1_0", "2.0", "1\0", "１２", "٠٢"]) {
        bool rejected;
        try { shiftCount([text]); }
        catch (UsageError error) { rejected = error.status == 2; }
        assert(rejected, text);
    }
    bool rejected;
    try { shiftCount(["1", "extra"]); }
    catch (UsageError error) { rejected = error.status == 2; }
    assert(rejected);
    assert(argumentRepr("a'b") == "\"a'b\"");
    assert(argumentRepr("a'\"b") == "'a\\'\"b'");
}
