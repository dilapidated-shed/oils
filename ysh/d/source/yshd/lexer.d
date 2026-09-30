module yshd.lexer;

import std.format : format;

import yshd.value : YshError;

class LexError : YshError {
    this(string message) {
        super(message);
    }
}

enum TokenKind {
    eof,
    newline,

    integer,
    floating,
    stringValue,
    doubleQuoted,
    charValue,
    name,

    nullKeyword,
    trueKeyword,
    falseKeyword,
    andKeyword,
    orKeyword,
    notKeyword,
    inKeyword,
    ifKeyword,
    elifKeyword,
    elseKeyword,

    varKeyword,
    constKeyword,
    setvarKeyword,
    setglobalKeyword,
    funcKeyword,
    procKeyword,
    returnKeyword,
    whileKeyword,
    forKeyword,
    breakKeyword,
    continueKeyword,

    plus,
    minus,
    star,
    slash,
    slashSlash,
    percent,
    starStar,
    plusPlus,
    amp,
    pipe,
    caret,
    tilde,
    shiftLeft,
    shiftRight,
    ellipsis,
    dotDotLess,
    dotDotEqual,

    less,
    greater,
    lessEqual,
    greaterEqual,
    tripleEqual,
    notDoubleEqual,
    equal,

    leftParen,
    rightParen,
    leftBracket,
    rightBracket,
    leftBrace,
    rightBrace,
    dot,
    colon,
    comma,
    at,
    dollar,
    question,
    semicolon,
}

struct Token {
    TokenKind kind;
    string text;
    size_t offset;
}

bool asciiDigit(char c) {
    return c >= '0' && c <= '9';
}

private bool asciiLetter(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

private bool identifierStart(char c) {
    return asciiLetter(c) || c == '_';
}

private bool identifierContinue(char c) {
    return identifierStart(c) || asciiDigit(c);
}

/// Shared lexer foundation for the D YSH frontend.
///
/// Expression parsing currently asks it to treat newlines as whitespace.
/// Command parsing asks it to emit newline tokens. This mirrors the fact that
/// the upstream frontend switches lexical/grammar modes rather than having
/// separate unrelated tokenizers.
class Lexer {
    private string input_;
    private size_t position_;
    private bool emitNewlines_;

    this(string input, bool emitNewlines = false) {
        input_ = input;
        emitNewlines_ = emitNewlines;
    }

    Token peek() {
        auto saved = position_;
        scope (exit) position_ = saved;
        return next();
    }

    Token next() {
        skipTrivia();
        if (position_ == input_.length) {
            return Token(TokenKind.eof, "", position_);
        }

        auto start = position_;
        auto c = input_[position_];

        if ((c == 'u' || c == 'b' || c == 'r') &&
                position_ + 1 < input_.length &&
                input_[position_ + 1] == '\'') {
            return prefixedSingleQuotedToken(c);
        }

        if (c == '\\') {
            return characterEscapeToken();
        }

        if (c == '"') {
            return doubleQuotedToken();
        }

        if (c == '\n') {
            ++position_;
            return Token(TokenKind.newline, "\n", start);
        }

        if (asciiDigit(c)) {
            return numberToken();
        }

        if (identifierStart(c)) {
            ++position_;
            while (position_ < input_.length && identifierContinue(input_[position_])) {
                ++position_;
            }
            auto text = input_[start .. position_];
            switch (text) {
            case "null":
                return Token(TokenKind.nullKeyword, text, start);
            case "true":
                return Token(TokenKind.trueKeyword, text, start);
            case "false":
                return Token(TokenKind.falseKeyword, text, start);
            case "and":
                return Token(TokenKind.andKeyword, text, start);
            case "or":
                return Token(TokenKind.orKeyword, text, start);
            case "not":
                return Token(TokenKind.notKeyword, text, start);
            case "in":
                return Token(TokenKind.inKeyword, text, start);
            case "if":
                return Token(TokenKind.ifKeyword, text, start);
            case "elif":
                return Token(TokenKind.elifKeyword, text, start);
            case "else":
                return Token(TokenKind.elseKeyword, text, start);
            case "var":
                return Token(TokenKind.varKeyword, text, start);
            case "const":
                return Token(TokenKind.constKeyword, text, start);
            case "setvar":
                return Token(TokenKind.setvarKeyword, text, start);
            case "setglobal":
                return Token(TokenKind.setglobalKeyword, text, start);
            case "func":
                return Token(TokenKind.funcKeyword, text, start);
            case "proc":
                return Token(TokenKind.procKeyword, text, start);
            case "return":
                return Token(TokenKind.returnKeyword, text, start);
            case "while":
                return Token(TokenKind.whileKeyword, text, start);
            case "for":
                return Token(TokenKind.forKeyword, text, start);
            case "break":
                return Token(TokenKind.breakKeyword, text, start);
            case "continue":
                return Token(TokenKind.continueKeyword, text, start);
            default:
                return Token(TokenKind.name, text, start);
            }
        }

        if (c == '\'') {
            ++position_;
            auto contentStart = position_;
            while (position_ < input_.length && input_[position_] != '\'') {
                ++position_;
            }
            if (position_ == input_.length) {
                throw new LexError(format(
                    "unterminated single-quoted string at byte %s", start));
            }
            auto text = input_[contentStart .. position_];
            ++position_;
            return Token(TokenKind.stringValue, text, start);
        }

        if (startsWith("!==")) {
            position_ += 3;
            return Token(TokenKind.notDoubleEqual, "!==", start);
        }
        if (startsWith("===")) {
            position_ += 3;
            return Token(TokenKind.tripleEqual, "===", start);
        }
        if (startsWith("//")) {
            position_ += 2;
            return Token(TokenKind.slashSlash, "//", start);
        }
        if (startsWith("**")) {
            position_ += 2;
            return Token(TokenKind.starStar, "**", start);
        }
        if (startsWith("++")) {
            position_ += 2;
            return Token(TokenKind.plusPlus, "++", start);
        }
        if (startsWith("...")) {
            position_ += 3;
            return Token(TokenKind.ellipsis, "...", start);
        }
        if (startsWith("..<")) {
            position_ += 3;
            return Token(TokenKind.dotDotLess, "..<", start);
        }
        if (startsWith("..=")) {
            position_ += 3;
            return Token(TokenKind.dotDotEqual, "..=", start);
        }
        if (startsWith("<<")) {
            position_ += 2;
            return Token(TokenKind.shiftLeft, "<<", start);
        }
        if (startsWith(">>")) {
            position_ += 2;
            return Token(TokenKind.shiftRight, ">>", start);
        }
        if (startsWith("<=")) {
            position_ += 2;
            return Token(TokenKind.lessEqual, "<=", start);
        }
        if (startsWith(">=")) {
            position_ += 2;
            return Token(TokenKind.greaterEqual, ">=", start);
        }

        ++position_;
        switch (c) {
        case '+':
            return Token(TokenKind.plus, "+", start);
        case '-':
            return Token(TokenKind.minus, "-", start);
        case '*':
            return Token(TokenKind.star, "*", start);
        case '/':
            return Token(TokenKind.slash, "/", start);
        case '%':
            return Token(TokenKind.percent, "%", start);
        case '&':
            return Token(TokenKind.amp, "&", start);
        case '|':
            return Token(TokenKind.pipe, "|", start);
        case '^':
            return Token(TokenKind.caret, "^", start);
        case '~':
            return Token(TokenKind.tilde, "~", start);
        case '<':
            return Token(TokenKind.less, "<", start);
        case '>':
            return Token(TokenKind.greater, ">", start);
        case '=':
            return Token(TokenKind.equal, "=", start);
        case '(':
            return Token(TokenKind.leftParen, "(", start);
        case ')':
            return Token(TokenKind.rightParen, ")", start);
        case '[':
            return Token(TokenKind.leftBracket, "[", start);
        case ']':
            return Token(TokenKind.rightBracket, "]", start);
        case '{':
            return Token(TokenKind.leftBrace, "{", start);
        case '}':
            return Token(TokenKind.rightBrace, "}", start);
        case '.':
            return Token(TokenKind.dot, ".", start);
        case ':':
            return Token(TokenKind.colon, ":", start);
        case ',':
            return Token(TokenKind.comma, ",", start);
        case '@':
            return Token(TokenKind.at, "@", start);
        case '$':
            return Token(TokenKind.dollar, "$", start);
        case '?':
            return Token(TokenKind.question, "?", start);
        case ';':
            return Token(TokenKind.semicolon, ";", start);
        default:
            throw new LexError(format("unexpected byte '%s' at byte %s", c, start));
        }
    }

    private void skipTrivia() {
        while (position_ < input_.length) {
            auto c = input_[position_];

            if (c == ' ' || c == '\t' || c == '\r') {
                ++position_;
                continue;
            }

            if (c == '\n') {
                if (emitNewlines_) {
                    return;
                }
                ++position_;
                continue;
            }

            if (c == '#') {
                while (position_ < input_.length && input_[position_] != '\n') {
                    ++position_;
                }
                if (emitNewlines_) {
                    return;
                }
                continue;
            }

            return;
        }
    }

    private bool startsWith(string spelling) {
        if (position_ + spelling.length > input_.length) {
            return false;
        }
        return input_[position_ .. position_ + spelling.length] == spelling;
    }

    private void scanDecimalIntPart() {
        assert(position_ < input_.length && asciiDigit(input_[position_]));
        ++position_;
        while (position_ < input_.length) {
            if (asciiDigit(input_[position_])) {
                ++position_;
                continue;
            }
            if (input_[position_] == '_' && position_ + 1 < input_.length &&
                    asciiDigit(input_[position_ + 1])) {
                position_ += 2;
                continue;
            }
            return;
        }
    }

    private Token numberToken() {
        auto start = position_;
        scanDecimalIntPart();
        bool isFloat = false;

        if (position_ + 1 < input_.length && input_[position_] == '.' &&
                asciiDigit(input_[position_ + 1])) {
            isFloat = true;
            ++position_;
            scanDecimalIntPart();
        }

        if (position_ < input_.length &&
                (input_[position_] == 'e' || input_[position_] == 'E')) {
            auto exponentStart = position_;
            size_t p = position_ + 1;
            if (p < input_.length && (input_[p] == '+' || input_[p] == '-')) {
                ++p;
            }
            if (p < input_.length && asciiDigit(input_[p])) {
                isFloat = true;
                position_ = p + 1;
                while (position_ < input_.length && asciiDigit(input_[position_])) {
                    ++position_;
                }
            } else {
                position_ = exponentStart;
            }
        }

        auto text = input_[start .. position_];
        return Token(isFloat ? TokenKind.floating : TokenKind.integer, text, start);
    }

    private Token characterEscapeToken() {
        auto start = position_;
        ++position_; // backslash
        if (position_ >= input_.length) {
            throw new LexError(format(
                "backslash at end of input at byte %s", start));
        }

        auto escape = input_[position_++];
        string text;

        switch (escape) {
        case 'a':
            text ~= cast(char)0x07;
            break;
        case 'b':
            text ~= cast(char)0x08;
            break;
        case 'e':
        case 'E':
            text ~= cast(char)0x1b;
            break;
        case 'f':
            text ~= cast(char)0x0c;
            break;
        case 'n':
            text ~= '\n';
            break;
        case 'r':
            text ~= '\r';
            break;
        case 't':
            text ~= '\t';
            break;
        case 'v':
            text ~= cast(char)0x0b;
            break;
        case '\\':
            text ~= '\\';
            break;
        case '\n':
            // Shell line continuation contributes no byte to the word.
            break;
        case 'y':
            if (position_ + 1 >= input_.length ||
                    !hexDigit(input_[position_]) ||
                    !hexDigit(input_[position_ + 1])) {
                throw new LexError(format(
                    "\\y requires exactly two hex digits at byte %s", start));
            }
            auto byteValue = (hexValue(input_[position_]) << 4) |
                hexValue(input_[position_ + 1]);
            text ~= cast(char)byteValue;
            position_ += 2;
            break;
        case 'u':
            if (position_ >= input_.length || input_[position_] != '{') {
                throw new LexError(format(
                    "expected '{' after \\u at byte %s", start));
            }
            ++position_;
            uint codePoint;
            size_t digits;
            while (position_ < input_.length && input_[position_] != '}') {
                if (!hexDigit(input_[position_]) || digits >= 6) {
                    throw new LexError(format(
                        "invalid \\u{...} escape at byte %s", start));
                }
                codePoint = codePoint * 16 + hexValue(input_[position_]);
                ++position_;
                ++digits;
            }
            if (position_ >= input_.length || digits == 0) {
                throw new LexError(format(
                    "unterminated \\u{...} escape at byte %s", start));
            }
            ++position_; // }
            appendUtf8(text, codePoint);
            break;
        default:
            // In command mode a backslash quotes an ordinary byte. In
            // expression mode this also gives the useful shell-compatible
            // literal spelling for punctuation.
            text ~= escape;
            break;
        }

        return Token(TokenKind.charValue, text, start);
    }

    private static bool hexDigit(char c) {
        return (c >= '0' && c <= '9') ||
            (c >= 'a' && c <= 'f') ||
            (c >= 'A' && c <= 'F');
    }

    private static uint hexValue(char c) {
        if (c >= '0' && c <= '9') {
            return cast(uint)(c - '0');
        }
        if (c >= 'a' && c <= 'f') {
            return cast(uint)(10 + c - 'a');
        }
        return cast(uint)(10 + c - 'A');
    }

    private static void appendUtf8(ref string result, uint codePoint) {
        if (codePoint > 0x10ffff ||
                (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
            throw new LexError("invalid Unicode scalar in string literal");
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

    private static bool stringWhitespace(char c) {
        return c == ' ' || c == '\t' || c == '\r';
    }

    /// Apply YSH's triple-quoted indentation rule: discard whitespace through
    /// the first newline, use the indentation before the closing delimiter as
    /// the per-line prefix, and remove that prefix where present.
    private static string trimTripleQuoted(string raw) {
        size_t start;
        size_t firstNewline;
        bool foundFirstNewline;
        bool leadingWhitespace = true;
        while (firstNewline < raw.length) {
            if (raw[firstNewline] == '\n') {
                foundFirstNewline = true;
                break;
            }
            if (!stringWhitespace(raw[firstNewline])) {
                leadingWhitespace = false;
            }
            ++firstNewline;
        }
        if (foundFirstNewline && leadingWhitespace) {
            start = firstNewline + 1;
        }

        size_t lastLine = raw.length;
        while (lastLine > start && raw[lastLine - 1] != '\n') {
            --lastLine;
        }

        auto indentStart = lastLine;
        bool closingIndentOnly = true;
        foreach (c; raw[indentStart .. $]) {
            if (!stringWhitespace(c)) {
                closingIndentOnly = false;
                break;
            }
        }

        string indent;
        size_t contentEnd = raw.length;
        if (closingIndentOnly) {
            indent = raw[indentStart .. $];
            contentEnd = indentStart;
        }

        auto body = raw[start .. contentEnd];
        if (indent.length == 0) {
            return body.idup;
        }

        string result;
        size_t lineStart;
        while (lineStart < body.length) {
            size_t lineEnd = lineStart;
            while (lineEnd < body.length && body[lineEnd] != '\n') {
                ++lineEnd;
            }

            auto line = body[lineStart .. lineEnd];
            if (line.length >= indent.length &&
                    line[0 .. indent.length] == indent) {
                line = line[indent.length .. $];
            }
            result ~= line;

            if (lineEnd < body.length) {
                result ~= '\n';
                lineStart = lineEnd + 1;
            } else {
                lineStart = lineEnd;
            }
        }
        return result;
    }

    private string decodeJ8StringContent(string raw, char prefix,
            size_t sourceStart) {
        if (prefix == 'r') {
            return raw.idup;
        }

        string text;
        size_t p;
        while (p < raw.length) {
            auto c = raw[p];
            if (c != '\\') {
                text ~= c;
                ++p;
                continue;
            }
            if (p + 1 >= raw.length) {
                throw new LexError(format(
                    "unterminated %s string escape at byte %s",
                    prefix, sourceStart + p));
            }

            auto escape = raw[p + 1];
            switch (escape) {
            case '\\':
                text ~= '\\';
                p += 2;
                break;
            case '\'':
                text ~= '\'';
                p += 2;
                break;
            case 'n':
                text ~= '\n';
                p += 2;
                break;
            case 'r':
                text ~= '\r';
                p += 2;
                break;
            case 't':
                text ~= '\t';
                p += 2;
                break;
            case '0':
                text ~= cast(char)0;
                p += 2;
                break;
            case 'u':
                if (p + 2 >= raw.length || raw[p + 2] != '{') {
                    throw new LexError(format(
                        "expected '{' after \\u at byte %s",
                        sourceStart + p));
                }
                size_t q = p + 3;
                uint codePoint;
                size_t digits;
                while (q < raw.length && raw[q] != '}') {
                    if (!hexDigit(raw[q]) || digits >= 6) {
                        throw new LexError(format(
                            "invalid \\u{...} escape at byte %s",
                            sourceStart + p));
                    }
                    codePoint = codePoint * 16 + hexValue(raw[q]);
                    ++q;
                    ++digits;
                }
                if (q >= raw.length || digits == 0) {
                    throw new LexError(format(
                        "unterminated \\u{...} escape at byte %s",
                        sourceStart + p));
                }
                appendUtf8(text, codePoint);
                p = q + 1;
                break;
            case 'y':
                if (prefix != 'b') {
                    throw new LexError(format(
                        "\\y byte escape requires b'' at byte %s",
                        sourceStart + p));
                }
                if (p + 3 >= raw.length ||
                        !hexDigit(raw[p + 2]) ||
                        !hexDigit(raw[p + 3])) {
                    throw new LexError(format(
                        "\\y requires exactly two hex digits at byte %s",
                        sourceStart + p));
                }
                auto byteValue = (hexValue(raw[p + 2]) << 4) |
                    hexValue(raw[p + 3]);
                text ~= cast(char)byteValue;
                p += 4;
                break;
            default:
                throw new LexError(format(
                    "invalid escape '\\%s' in %s string at byte %s",
                    escape, prefix, sourceStart + p));
            }
        }
        return text;
    }

    private Token prefixedTripleQuotedToken(char prefix) {
        auto start = position_;
        position_ += 4; // prefix and opening '''
        auto contentStart = position_;

        while (position_ + 2 < input_.length) {
            if (input_[position_ .. position_ + 3] == "'''") {
                auto raw = input_[contentStart .. position_];
                position_ += 3;
                auto trimmed = trimTripleQuoted(raw);
                auto text = decodeJ8StringContent(
                    trimmed, prefix, contentStart);
                return Token(TokenKind.stringValue, text, start);
            }
            ++position_;
        }

        throw new LexError(format(
            "unterminated triple-quoted %s string at byte %s",
            prefix, start));
    }

    /// Translate J8-style r'', u'', and b'' literals exposed by YSH,
    /// including their triple-quoted forms.
    private Token prefixedSingleQuotedToken(char prefix) {
        auto start = position_;
        if (position_ + 3 < input_.length &&
                input_[position_ + 1 .. position_ + 4] == "'''") {
            return prefixedTripleQuotedToken(prefix);
        }
        position_ += 2; // prefix and opening quote

        string text;
        while (position_ < input_.length) {
            auto c = input_[position_];

            if (c == '\'') {
                ++position_;
                return Token(TokenKind.stringValue, text, start);
            }

            if (prefix == 'r' || c != '\\') {
                text ~= c;
                ++position_;
                continue;
            }

            if (position_ + 1 >= input_.length) {
                throw new LexError(format(
                    "unterminated %s string at byte %s", prefix, start));
            }

            auto escape = input_[position_ + 1];
            switch (escape) {
            case '\\':
                text ~= '\\';
                position_ += 2;
                break;
            case '\'':
                text ~= '\'';
                position_ += 2;
                break;
            case 'n':
                text ~= '\n';
                position_ += 2;
                break;
            case 'r':
                text ~= '\r';
                position_ += 2;
                break;
            case 't':
                text ~= '\t';
                position_ += 2;
                break;
            case '0':
                text ~= cast(char)0;
                position_ += 2;
                break;
            case 'u':
                if (position_ + 2 >= input_.length ||
                        input_[position_ + 2] != '{') {
                    throw new LexError(format(
                        "expected '{' after \\u at byte %s", position_));
                }
                size_t p = position_ + 3;
                uint codePoint;
                size_t digits;
                while (p < input_.length && input_[p] != '}') {
                    if (!hexDigit(input_[p]) || digits >= 6) {
                        throw new LexError(format(
                            "invalid \\u{...} escape at byte %s", position_));
                    }
                    codePoint = codePoint * 16 + hexValue(input_[p]);
                    ++p;
                    ++digits;
                }
                if (p >= input_.length || digits == 0) {
                    throw new LexError(format(
                        "unterminated \\u{...} escape at byte %s", position_));
                }
                appendUtf8(text, codePoint);
                position_ = p + 1;
                break;
            case 'y':
                if (prefix != 'b') {
                    throw new LexError(format(
                        "\\y byte escape requires b'' at byte %s", position_));
                }
                if (position_ + 3 >= input_.length ||
                        !hexDigit(input_[position_ + 2]) ||
                        !hexDigit(input_[position_ + 3])) {
                    throw new LexError(format(
                        "\\y requires exactly two hex digits at byte %s",
                        position_));
                }
                auto byteValue = (hexValue(input_[position_ + 2]) << 4) |
                    hexValue(input_[position_ + 3]);
                text ~= cast(char)byteValue;
                position_ += 4;
                break;
            default:
                throw new LexError(format(
                    "invalid escape '\\%s' in %s string at byte %s",
                    escape, prefix, position_));
            }
        }

        throw new LexError(format(
            "unterminated %s string at byte %s", prefix, start));
    }

    private void skipQuotedSpan(char quote, size_t start) {
        ++position_; // opening quote
        while (position_ < input_.length) {
            if (input_[position_] == '\\') {
                if (position_ + 1 >= input_.length) {
                    break;
                }
                position_ += 2;
                continue;
            }
            if (input_[position_] == quote) {
                ++position_;
                return;
            }
            ++position_;
        }
        throw new LexError(format(
            "unterminated quote in substitution at byte %s", start));
    }

    private void skipDollarDelimited(char open, char close, size_t start) {
        // position_ is on the dollar byte and the next byte is OPEN.
        position_ += 2;
        int depth = 1;
        while (position_ < input_.length) {
            auto ch = input_[position_];
            if (ch == '\\') {
                if (position_ + 1 >= input_.length) {
                    break;
                }
                position_ += 2;
                continue;
            }
            if (ch == '\'' || ch == '"') {
                skipQuotedSpan(ch, position_);
                continue;
            }
            if ((ch == 'u' || ch == 'b' || ch == 'r') &&
                    position_ + 1 < input_.length &&
                    input_[position_ + 1] == '\'') {
                ++position_;
                skipQuotedSpan('\'', position_);
                continue;
            }
            if (ch == open) {
                ++depth;
                ++position_;
                continue;
            }
            if (ch == close) {
                --depth;
                ++position_;
                if (depth == 0) {
                    return;
                }
                continue;
            }
            ++position_;
        }
        throw new LexError(format(
            "unterminated substitution at byte %s", start));
    }

    private Token doubleQuotedToken() {
        auto start = position_;
        ++position_;
        auto contentStart = position_;
        while (position_ < input_.length) {
            if (input_[position_] == '$' &&
                    position_ + 1 < input_.length &&
                    (input_[position_ + 1] == '[' ||
                     input_[position_ + 1] == '(')) {
                auto open = input_[position_ + 1];
                skipDollarDelimited(open, open == '[' ? ']' : ')', position_);
                continue;
            }
            if (input_[position_] == '"') {
                auto text = input_[contentStart .. position_];
                ++position_;
                return Token(TokenKind.doubleQuoted, text, start);
            }
            if (input_[position_] == '\\') {
                if (position_ + 1 == input_.length) {
                    break;
                }
                position_ += 2;
            } else {
                ++position_;
            }
        }
        throw new LexError(format(
            "unterminated double-quoted string at byte %s", start));
    }

}

unittest {
    auto exprLexer = new Lexer("var + 1\n2");
    assert(exprLexer.next().kind == TokenKind.varKeyword);
    assert(exprLexer.next().kind == TokenKind.plus);
    assert(exprLexer.next().kind == TokenKind.integer);
    assert(exprLexer.next().kind == TokenKind.integer);

    auto charLexer = new Lexer("\\u{3bc} \\y41 \\n \\*");
    assert(charLexer.next().text == "μ");
    assert(charLexer.next().text == "A");
    assert(charLexer.next().text == "\n");
    assert(charLexer.next().text == "*");

    auto tripleLexer = new Lexer(
        "u'''\n  alpha\n  \\u{3bc}\n  ''' " ~
        "b'''\n  \\y61\n  ''' " ~
        "r'''\n  \\u{61}\n  '''");
    assert(tripleLexer.next().text == "alpha\nμ\n");
    assert(tripleLexer.next().text == "a\n");
    assert(tripleLexer.next().text == "\\u{61}\n");

    auto stringLexer = new Lexer("u'\\u{3bc}' b'\\yff' r'raw \\u{61}'");
    auto unicodeString = stringLexer.next();
    assert(unicodeString.kind == TokenKind.stringValue);
    assert(unicodeString.text == "μ");
    auto byteString = stringLexer.next();
    assert(byteString.kind == TokenKind.stringValue);
    assert(byteString.text.length == 1);
    assert(cast(ubyte)byteString.text[0] == 0xff);
    auto rawString = stringLexer.next();
    assert(rawString.kind == TokenKind.stringValue);
    assert(rawString.text == "raw \\u{61}");

    auto nestedDouble = new Lexer("\"value $[d[\"key\"]] and $(printf x)\"");
    auto nestedToken = nestedDouble.next();
    assert(nestedToken.kind == TokenKind.doubleQuoted);
    assert(nestedToken.text == "value $[d[\"key\"]] and $(printf x)");

    auto commandLexer = new Lexer("var x = 1 # comment\nsetvar x = 2\n", true);
    assert(commandLexer.next().kind == TokenKind.varKeyword);
    assert(commandLexer.next().kind == TokenKind.name);
    assert(commandLexer.next().kind == TokenKind.equal);
    assert(commandLexer.next().kind == TokenKind.integer);
    assert(commandLexer.next().kind == TokenKind.newline);
    assert(commandLexer.next().kind == TokenKind.setvarKeyword);
}
