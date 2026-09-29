module yshd.io_ysh;

import std.format : format;

import yshd.value : Value, ValueKind, YshTypeError, stringify;

/// Translate ysh/val_ops.py:ToShellArray for the D value types.
string[] spliceArray(Value value) {
    if (value.kind != ValueKind.list) {
        throw new YshTypeError("Splice expected List");
    }

    string[] result;
    foreach (item; value.listValue.items) {
        result ~= stringify(item);
    }
    return result;
}

/// String encoding mode used by builtin/io_ysh.py:Write.
enum WriteEncoding {
    plain,
    json,
    j8,
}

private bool isHexDigit(char c) {
    return (c >= '0' && c <= '9') ||
        (c >= 'a' && c <= 'f') ||
        (c >= 'A' && c <= 'F');
}

private uint hexValue(char c) {
    if (c >= '0' && c <= '9') {
        return cast(uint)(c - '0');
    }
    if (c >= 'a' && c <= 'f') {
        return cast(uint)(10 + c - 'a');
    }
    return cast(uint)(10 + c - 'A');
}

private char hexDigit(uint value) {
    return "0123456789abcdef"[value & 0xf];
}

private void appendUtf8(ref string result, uint codePoint) {
    // Unicode scalar values only. Invalid scalar values become U+FFFD, which
    // is also what the lossy JSON path uses for invalid UTF-8 input.
    if (codePoint > 0x10ffff ||
            (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
        codePoint = 0xfffd;
    }

    if (codePoint <= 0x7f) {
        result ~= cast(char)codePoint;
    } else if (codePoint <= 0x7ff) {
        result ~= cast(char)(0xc0 | (codePoint >> 6));
        result ~= cast(char)(0x80 | (codePoint & 0x3f));
    } else if (codePoint <= 0xffff) {
        result ~= cast(char)(0xe0 | (codePoint >> 12));
        result ~= cast(char)(0x80 | ((codePoint >> 6) & 0x3f));
        result ~= cast(char)(0x80 | (codePoint & 0x3f));
    } else {
        result ~= cast(char)(0xf0 | (codePoint >> 18));
        result ~= cast(char)(0x80 | ((codePoint >> 12) & 0x3f));
        result ~= cast(char)(0x80 | ((codePoint >> 6) & 0x3f));
        result ~= cast(char)(0x80 | (codePoint & 0x3f));
    }
}

private bool isContinuation(ubyte b) {
    return b >= 0x80 && b <= 0xbf;
}

/// Return the byte length of a valid UTF-8 scalar at offset, or zero.
private size_t utf8ScalarLength(string value, size_t offset) {
    auto first = cast(ubyte)value[offset];

    if (first <= 0x7f) {
        return 1;
    }

    if (first >= 0xc2 && first <= 0xdf) {
        if (offset + 1 < value.length &&
                isContinuation(cast(ubyte)value[offset + 1])) {
            return 2;
        }
        return 0;
    }

    if (first >= 0xe0 && first <= 0xef) {
        if (offset + 2 >= value.length) {
            return 0;
        }
        auto second = cast(ubyte)value[offset + 1];
        auto third = cast(ubyte)value[offset + 2];
        if (!isContinuation(third)) {
            return 0;
        }
        if (first == 0xe0) {
            return second >= 0xa0 && second <= 0xbf ? 3 : 0;
        }
        if (first == 0xed) {
            return second >= 0x80 && second <= 0x9f ? 3 : 0;
        }
        return isContinuation(second) ? 3 : 0;
    }

    if (first >= 0xf0 && first <= 0xf4) {
        if (offset + 3 >= value.length) {
            return 0;
        }
        auto second = cast(ubyte)value[offset + 1];
        auto third = cast(ubyte)value[offset + 2];
        auto fourth = cast(ubyte)value[offset + 3];
        if (!isContinuation(third) || !isContinuation(fourth)) {
            return 0;
        }
        if (first == 0xf0) {
            return second >= 0x90 && second <= 0xbf ? 4 : 0;
        }
        if (first == 0xf4) {
            return second >= 0x80 && second <= 0x8f ? 4 : 0;
        }
        return isContinuation(second) ? 4 : 0;
    }

    return 0;
}

private bool validUtf8(string value) {
    size_t offset;
    while (offset < value.length) {
        auto length = utf8ScalarLength(value, offset);
        if (length == 0) {
            return false;
        }
        offset += length;
    }
    return true;
}

/// data_lang/j8.py:MaybeEncodeJsonString semantics for strings.
///
/// JSON has no byte-string form, so malformed UTF-8 bytes are replaced with
/// U+FFFD before JSON quoting.
string encodeJsonString(string value) {
    string result = "\"";
    size_t offset;

    while (offset < value.length) {
        auto byteValue = cast(ubyte)value[offset];

        if (byteValue < 0x80) {
            switch (byteValue) {
            case '"':
                result ~= "\\\"";
                break;
            case '\\':
                result ~= "\\\\";
                break;
            case 0x08:
                result ~= "\\b";
                break;
            case 0x09:
                result ~= "\\t";
                break;
            case 0x0a:
                result ~= "\\n";
                break;
            case 0x0c:
                result ~= "\\f";
                break;
            case 0x0d:
                result ~= "\\r";
                break;
            default:
                if (byteValue < 0x20) {
                    result ~= "\\u00";
                    result ~= hexDigit(byteValue >> 4);
                    result ~= hexDigit(byteValue);
                } else {
                    result ~= cast(char)byteValue;
                }
                break;
            }
            ++offset;
            continue;
        }

        auto length = utf8ScalarLength(value, offset);
        if (length == 0) {
            appendUtf8(result, 0xfffd);
            ++offset;
        } else {
            result ~= value[offset .. offset + length];
            offset += length;
        }
    }

    result ~= '"';
    return result;
}

/// data_lang/j8.py:MaybeEncodeString semantics for the string cases reached by
/// `write --j8`. Valid UTF-8 is rendered as a normal quoted string. Any
/// malformed byte switches the whole value to J8's b'...' byte-string form.
string encodeJ8String(string value) {
    if (validUtf8(value)) {
        return encodeJsonString(value);
    }

    string result = "b'";
    foreach (char raw; value) {
        auto byteValue = cast(ubyte)raw;
        switch (byteValue) {
        case '\\':
            result ~= "\\\\";
            break;
        case '\'':
            result ~= "\\'";
            break;
        case '\n':
            result ~= "\\n";
            break;
        case '\r':
            result ~= "\\r";
            break;
        case '\t':
            result ~= "\\t";
            break;
        default:
            if (byteValue >= 0x20 && byteValue <= 0x7e) {
                result ~= cast(char)byteValue;
            } else {
                result ~= "\\y";
                result ~= hexDigit(byteValue >> 4);
                result ~= hexDigit(byteValue);
            }
            break;
        }
    }
    result ~= "'";
    return result;
}

private string encodeWriteArgument(string value, WriteEncoding encoding) {
    final switch (encoding) {
    case WriteEncoding.plain:
        return value;
    case WriteEncoding.json:
        return encodeJsonString(value);
    case WriteEncoding.j8:
        return encodeJ8String(value);
    }
}

/// Render builtin/io_ysh.py:Write for already-expanded string arguments.
string renderWrite(string[] arguments, string separator = "\n",
        string ending = "\n", WriteEncoding encoding = WriteEncoding.plain) {
    string result;
    foreach (index, argument; arguments) {
        if (index != 0) {
            result ~= separator;
        }
        result ~= encodeWriteArgument(argument, encoding);
    }
    return result ~ ending;
}

private struct EchoEscapeResult {
    string text;
    bool stop;
}

/// Decode the escape language consumed by frontend/match.py:EchoLexer and
/// osh/word_compile.py:EvalCStringToken. The special \\c escape terminates
/// the current argument, suppresses following arguments, and suppresses the
/// final newline.
private EchoEscapeResult decodeEchoEscapes(string value) {
    EchoEscapeResult result;
    size_t i;

    while (i < value.length) {
        if (value[i] != '\\' || i + 1 >= value.length) {
            result.text ~= value[i];
            ++i;
            continue;
        }

        auto escape = value[i + 1];
        switch (escape) {
        case '\\':
            result.text ~= '\\';
            i += 2;
            break;
        case 'a':
            result.text ~= cast(char)0x07;
            i += 2;
            break;
        case 'b':
            result.text ~= cast(char)0x08;
            i += 2;
            break;
        case 'c':
            result.stop = true;
            return result;
        case 'e':
        case 'E':
            result.text ~= cast(char)0x1b;
            i += 2;
            break;
        case 'f':
            result.text ~= cast(char)0x0c;
            i += 2;
            break;
        case 'n':
            result.text ~= '\n';
            i += 2;
            break;
        case 'r':
            result.text ~= '\r';
            i += 2;
            break;
        case 't':
            result.text ~= '\t';
            i += 2;
            break;
        case 'v':
            result.text ~= cast(char)0x0b;
            i += 2;
            break;
        case '0':
            // Bash/Oils echo consumes up to three octal digits after the 0
            // and emits the low byte (so \\0400 is NUL).
            uint number;
            size_t p = i + 2;
            size_t digits;
            while (p < value.length && digits < 3 &&
                    value[p] >= '0' && value[p] <= '7') {
                number = number * 8 + cast(uint)(value[p] - '0');
                ++p;
                ++digits;
            }
            result.text ~= cast(char)(number & 0xff);
            i = p;
            break;
        case 'x':
            size_t p = i + 2;
            if (p >= value.length || !isHexDigit(value[p])) {
                result.text ~= "\\x";
                i += 2;
                break;
            }
            uint number;
            size_t digits;
            while (p < value.length && digits < 2 && isHexDigit(value[p])) {
                number = number * 16 + hexValue(value[p]);
                ++p;
                ++digits;
            }
            result.text ~= cast(char)(number & 0xff);
            i = p;
            break;
        case 'u':
        case 'U':
            auto maxDigits = escape == 'u' ? 4 : 8;
            size_t p = i + 2;
            if (p >= value.length || !isHexDigit(value[p])) {
                result.text ~= '\\';
                result.text ~= escape;
                i += 2;
                break;
            }
            uint number;
            size_t digits;
            while (p < value.length && digits < maxDigits && isHexDigit(value[p])) {
                number = number * 16 + hexValue(value[p]);
                ++p;
                ++digits;
            }
            appendUtf8(result.text, number);
            i = p;
            break;
        default:
            // Unknown escapes preserve the backslash, matching Oils echo.
            result.text ~= '\\';
            result.text ~= escape;
            i += 2;
            break;
        }
    }

    return result;
}

/// Render YSH-visible OSH `echo` behavior from builtin/io_osh.py.
string renderEcho(string[] arguments, bool noNewline = false,
        bool interpretEscapes = false) {
    string result;

    foreach (index, argument; arguments) {
        if (index != 0) {
            result ~= " ";
        }

        if (!interpretEscapes) {
            result ~= argument;
            continue;
        }

        auto decoded = decodeEchoEscapes(argument);
        result ~= decoded.text;
        if (decoded.stop) {
            return result;
        }
    }

    if (!noNewline) {
        result ~= "\n";
    }
    return result;
}

unittest {
    assert(renderWrite(["a", "b"]) == "a\nb\n");
    assert(renderWrite(["a", "b"], "_", " END") == "a_b END");
    assert(renderWrite(["x"], "\n", "") == "x");
    assert(renderWrite([]) == "\n");

    assert(renderWrite(["μ", "x"], "\n", "\n", WriteEncoding.json) ==
        "\"μ\"\n\"x\"\n");
    assert(renderWrite(["μ", "x"], "\n", "\n", WriteEncoding.j8) ==
        "\"μ\"\n\"x\"\n");

    string invalidBytes;
    invalidBytes ~= cast(char)0xfe;
    invalidBytes ~= cast(char)0xff;
    assert(encodeJsonString(invalidBytes) == "\"��\"");
    assert(encodeJ8String(invalidBytes) == "b'\\yfe\\yff'");

    assert(renderEcho(["hello", "world"]) == "hello world\n");
    assert(renderEcho(["joined"], true) == "joined");
    assert(renderEcho([]) == "\n");
    assert(renderEcho(["abc\\ndef\\n"], true, true) == "abc\ndef\n");
    assert(renderEcho(["xy", "ab\\cde", "zzz"], false, true) == "xy ab");
    assert(renderEcho(["abcd\\x65f"], false, true) == "abcdef\n");
    assert(renderEcho(["abcd\\044e"], false, true) == "abcd$e\n");
    assert(renderEcho(["abcd\\u0065f"], false, true) == "abcdef\n");
    assert(renderEcho(["\\x", "\\xg"], false, true) == "\\x \\xg\n");
    assert(renderEcho(["\\0", "\\1", "\\8"], true, true) ==
        "\0 \\1 \\8");

    assert(spliceArray(Value.list([
        Value.str("a b"), Value.integer(42), Value.boolean(false),
    ])) == ["a b", "42", "false"]);

    bool rejectedNonList;
    try {
        spliceArray(Value.integer(42));
    } catch (YshTypeError error) {
        rejectedNonList = true;
    }
    assert(rejectedNonList);
}
