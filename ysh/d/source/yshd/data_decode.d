/// JSON/J8 decoding, translated from data_lang/j8.py and frontend/lexer_def.py.
module yshd.data_decode;

import std.bigint : BigInt;
import std.conv : to;
import std.format : format;
import yshd.io_ysh : utf8ScalarLength;
import yshd.value : Value, YshError;

class DataDecodeError : YshError {
    size_t startPosition;
    size_t endPosition;
    size_t lineNumber;
    this(string message, size_t start, size_t end, size_t line) {
        super(message, 4);
        startPosition = start;
        endPosition = end;
        lineNumber = line;
    }
}

private enum Kind { end, unknown, stringValue, integer, floating,
    nullValue, trueValue, falseValue, leftList, rightList, leftDict, rightDict, comma, colon }

private int hexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Unlike std.utf.encode this deliberately preserves JSON's unpaired surrogate
// escape as three bytes. Raw surrogate UTF-8 remains invalid input.
private void appendCodePoint(ref string output, uint code) {
    if (code < 0x80) output ~= cast(char)code;
    else if (code < 0x800) {
        output ~= cast(char)(0xc0 | code >> 6);
        output ~= cast(char)(0x80 | (code & 63));
    } else if (code < 0x10000) {
        output ~= cast(char)(0xe0 | code >> 12);
        output ~= cast(char)(0x80 | ((code >> 6) & 63));
        output ~= cast(char)(0x80 | (code & 63));
    } else {
        output ~= cast(char)(0xf0 | code >> 18);
        output ~= cast(char)(0x80 | ((code >> 12) & 63));
        output ~= cast(char)(0x80 | ((code >> 6) & 63));
        output ~= cast(char)(0x80 | (code & 63));
    }
}

private class Decoder {
    string source;
    bool j8;
    size_t position, start, end, line = 1, depth;
    Kind kind;
    string decoded;

    this(string source, bool j8) { this.source = source; this.j8 = j8; }

    private DataDecodeError error(string message) {
        return new DataDecodeError(message, start, end, line);
    }

    private uint hex(size_t count) {
        uint result;
        foreach (i; 0 .. count) {
            if (position >= source.length || hexDigit(source[position]) < 0) {
                end = position;
                throw error("Bad backslash escape in string");
            }
            result = (result << 4) | hexDigit(source[position++]);
        }
        return result;
    }

    private string stringToken(char quote, bool bytes) {
        string output;
        ++position; // opening quote
        while (position < source.length) {
            char ch = source[position++];
            end = position;
            if (ch == quote) return output;
            if (cast(ubyte)ch < 32) throw error("ASCII control chars can't appear unescaped in strings");
            if (ch != '\\') {
                auto length = utf8ScalarLength(source, position - 1);
                if (!length) throw error("Invalid UTF-8 in string literal");
                output ~= source[position - 1 .. position - 1 + length];
                position += length - 1;
                continue;
            }
            if (position == source.length) break;
            ch = source[position++];
            end = position;
            switch (ch) {
            case '\\': case '"': case '/': output ~= ch; break;
            case '\'':
                if (quote != '\'') throw error("Bad backslash escape in JSON string");
                output ~= ch;
                break;
            case 'b': output ~= '\b'; break;
            case 'f': output ~= '\f'; break;
            case 'n': output ~= '\n'; break;
            case 'r': output ~= '\r'; break;
            case 't': output ~= '\t'; break;
            case 'y':
                if (quote != '\'' || !bytes) throw error("Byte escapes not allowed in Unicode strings");
                output ~= cast(char)hex(2);
                break;
            case 'u':
                uint code;
                if (quote == '\'') {
                    if (position == source.length || source[position++] != '{')
                        throw error("Bad backslash escape in J8 string");
                    auto first = position;
                    while (position < source.length && hexDigit(source[position]) >= 0) {
                        if (position - first == 6) throw error("Code point can't be greater than U+10ffff");
                        code = (code << 4) | hexDigit(source[position++]);
                    }
                    end = position;
                    if (position == first || position == source.length || source[position++] != '}')
                        throw error("Bad Unicode escape in J8 string");
                    if (code > 0x10ffff) throw error("Code point can't be greater than U+10ffff");
                    if (code >= 0xd800 && code < 0xe000) throw error("Unicode escape is in the surrogate range");
                } else {
                    code = hex(4);
                    if (code >= 0xd800 && code <= 0xdbff && position + 6 <= source.length &&
                            source[position .. position + 2] == "\\u") {
                        uint low;
                        bool valid = true;
                        foreach (c; source[position + 2 .. position + 6]) {
                            auto digit = hexDigit(c);
                            if (digit < 0) { valid = false; break; }
                            low = (low << 4) | digit;
                        }
                        if (valid && low >= 0xdc00 && low <= 0xdfff) {
                            position += 6;
                            code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00;
                        }
                    }
                }
                appendCodePoint(output, code);
                break;
            default: throw error("Bad backslash escape in string");
            }
        }
        end = position;
        throw error("Unexpected EOF while lexing string");
    }

    private static bool digit(char c) { return c >= '0' && c <= '9'; }
    private static bool identifier(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || digit(c) || c == '_';
    }

    void next() {
        while (position < source.length) {
            auto ch = source[position];
            if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
                if (ch == '\n') ++line;
                ++position;
            } else if (ch == '#') {
                start = position;
                while (position < source.length && source[position] != '\n') ++position;
                end = position;
                if (!j8) throw error("Comments aren't part of JSON; you may want 'json8 read'");
            } else break;
        }
        start = position;
        end = position;
        decoded = "";
        if (position == source.length) { kind = Kind.end; return; }
        auto ch = source[position++];
        end = position;
        switch (ch) {
        case '[': kind = Kind.leftList; return;
        case ']': kind = Kind.rightList; return;
        case '{': kind = Kind.leftDict; return;
        case '}': kind = Kind.rightDict; return;
        case ',': kind = Kind.comma; return;
        case ':': kind = Kind.colon; return;
        default: break;
        }
        bool prefixed = position < source.length &&
            (((ch == 'u' || ch == 'b') && source[position] == '\'') || (ch == 'j' && source[position] == '"'));
        if (ch == '"' || ch == '\'' || prefixed) {
            if ((ch != '"') && !j8) throw error("Single quotes and string prefixes aren't part of JSON");
            auto quote = prefixed ? source[position] : ch;
            if (!prefixed) --position;
            decoded = stringToken(quote, ch == 'b');
            end = position;
            kind = Kind.stringValue;
            return;
        }
        if (digit(ch) || (ch == '-' && position < source.length && digit(source[position]))) {
            position = start;
            if (source[position] == '-') ++position;
            if (source[position] == '0') ++position;
            else while (position < source.length && digit(source[position])) ++position;
            kind = Kind.integer;
            if (position + 1 < source.length && source[position] == '.' && digit(source[position + 1])) {
                kind = Kind.floating;
                position += 2;
                while (position < source.length && digit(source[position])) ++position;
            }
            if (position < source.length && (source[position] == 'e' || source[position] == 'E')) {
                auto exponent = position + 1;
                if (exponent < source.length && (source[exponent] == '+' || source[exponent] == '-')) ++exponent;
                if (exponent < source.length && digit(source[exponent])) {
                    kind = Kind.floating;
                    position = exponent + 1;
                    while (position < source.length && digit(source[position])) ++position;
                }
            }
            end = position;
            return;
        }
        if (identifier(ch)) {
            while (position < source.length && identifier(source[position])) ++position;
            end = position;
            switch (source[start .. end]) {
            case "true": kind = Kind.trueValue; return;
            case "false": kind = Kind.falseValue; return;
            case "null": kind = Kind.nullValue; return;
            default: break;
            }
        }
        kind = Kind.unknown;
    }

    private void eat(Kind expected, string name) {
        if (kind != expected) throw error("Expected Id.J8_" ~ name);
        next();
    }

    Value value() {
        ++depth;
        scope (exit) --depth;
        if (depth > 1000) throw error("JSON/J8 nesting limit exceeded");
        switch (kind) {
        case Kind.leftList:
            Value[] items;
            next();
            if (kind != Kind.rightList) {
                items ~= value();
                while (kind == Kind.comma) { next(); items ~= value(); }
            }
            eat(Kind.rightList, "RBracket");
            return Value.list(items);
        case Kind.leftDict:
            auto result = Value.dict();
            next();
            if (kind != Kind.rightDict) {
                while (true) {
                    auto key = decoded;
                    eat(Kind.stringValue, "String");
                    eat(Kind.colon, "Colon");
                    result.dictValue.set(key, value());
                    if (kind != Kind.comma) break;
                    next();
                }
            }
            eat(Kind.rightDict, "RBrace");
            return result;
        case Kind.nullValue: next(); return Value.nullValue();
        case Kind.trueValue: next(); return Value.boolean(true);
        case Kind.falseValue: next(); return Value.boolean(false);
        case Kind.stringValue:
            auto text = decoded;
            next();
            return Value.str(text);
        case Kind.integer:
            auto number = BigInt(source[start .. end]);
            next();
            if (number < BigInt(long.min) || number > BigInt(long.max)) throw error("Integer is too big");
            return Value.integer(number);
        case Kind.floating:
            import core.stdc.stdlib : strtod;
            import std.string : toStringz;
            auto number = strtod(toStringz(source[start .. end]), null);
            next();
            return Value.floating(number);
        case Kind.end: throw error("Unexpected EOF while parsing " ~ (j8 ? "J8" : "JSON"));
        default: throw error("Invalid token while parsing " ~ (j8 ? "J8" : "JSON"));
        }
    }

    Value parse() {
        next();
        auto result = value();
        if (kind != Kind.end) throw error(format("Got %s bytes of unexpected trailing input", source.length - start));
        return result;
    }
}

Value decodeDataValue(string source, bool j8 = false) {
    return (new Decoder(source, j8)).parse();
}

unittest {
    import yshd.value : repr;
    assert(repr(decodeDataValue(` {"x": [true, null, -1, 2.5], "x": "last"} `)) == `{"x": "last"}`);
    assert(decodeDataValue(`"\ud83e\udd26"`).stringValue == "🤦");
    assert(decodeDataValue(`"\ud83e"`).stringValue == "\xed\xa0\xbe");
    assert(decodeDataValue(`b'\yff\u{3bc}' # comment`, true).stringValue == "\xffμ");
    foreach (bad; [`[1,]`, `{"x":0,}`, `truex`, `01`, `1.`, `1e`, `1]`, `"\'"`, `"\u{1}"`, `9223372036854775808`, "\"\xff\""]) {
        bool failed;
        try { decodeDataValue(bad); } catch (DataDecodeError e) { failed = true; }
        assert(failed, bad);
    }
    foreach (bad; [`u'\yff'`, `'\u{d800}'`, `b'\x41'`, `u'\u0041'`]) {
        bool failed;
        try { decodeDataValue(bad, true); } catch (DataDecodeError e) { failed = true; }
        assert(failed, bad);
    }
    try { decodeDataValue("[+]"); assert(false); }
    catch (DataDecodeError e) { assert(e.startPosition == 1 && e.endPosition == 2); }
}
