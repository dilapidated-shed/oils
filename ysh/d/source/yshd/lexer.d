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
    name,

    nullKeyword,
    trueKeyword,
    falseKeyword,
    andKeyword,
    orKeyword,
    notKeyword,
    inKeyword,
    ifKeyword,
    elseKeyword,

    varKeyword,
    constKeyword,
    setvarKeyword,
    setglobalKeyword,

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

    Token next() {
        skipTrivia();
        if (position_ == input_.length) {
            return Token(TokenKind.eof, "", position_);
        }

        auto start = position_;
        auto c = input_[position_];

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
}

unittest {
    auto exprLexer = new Lexer("var + 1\n2");
    assert(exprLexer.next().kind == TokenKind.varKeyword);
    assert(exprLexer.next().kind == TokenKind.plus);
    assert(exprLexer.next().kind == TokenKind.integer);
    assert(exprLexer.next().kind == TokenKind.integer);

    auto commandLexer = new Lexer("var x = 1 # comment\nsetvar x = 2\n", true);
    assert(commandLexer.next().kind == TokenKind.varKeyword);
    assert(commandLexer.next().kind == TokenKind.name);
    assert(commandLexer.next().kind == TokenKind.equal);
    assert(commandLexer.next().kind == TokenKind.integer);
    assert(commandLexer.next().kind == TokenKind.newline);
    assert(commandLexer.next().kind == TokenKind.setvarKeyword);
}
