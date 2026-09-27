module yshd.expr;

import std.bigint : BigInt, toDecimalString;
import std.conv : to;
import std.format : format;
import std.string : replace, strip;

import yshd.value : Value, ValueKind, YshError, YshTypeError, exactlyEqual, toBool;

class ParseError : YshError {
    this(string message) {
        super(message);
    }
}

private enum TokenKind {
    eof,
    integer,
    floating,
    stringValue,
    nullKeyword,
    trueKeyword,
    falseKeyword,
    andKeyword,
    orKeyword,
    notKeyword,
    plus,
    minus,
    star,
    slash,
    slashSlash,
    percent,
    starStar,
    plusPlus,
    less,
    greater,
    lessEqual,
    greaterEqual,
    tripleEqual,
    notDoubleEqual,
    leftParen,
    rightParen,
    leftBracket,
    rightBracket,
    comma,
}

private struct Token {
    TokenKind kind;
    string text;
    size_t offset;
}

private bool asciiDigit(char c) {
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

private class Lexer {
    private string input_;
    private size_t position_;

    this(string input) {
        input_ = input;
    }

    Token next() {
        skipSpace();
        if (position_ == input_.length) {
            return Token(TokenKind.eof, "", position_);
        }

        auto start = position_;
        auto c = input_[position_];

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
            default:
                throw new ParseError(format("unsupported name '%s' at byte %s", text, start));
            }
        }

        if (c == '\'') {
            ++position_;
            auto contentStart = position_;
            while (position_ < input_.length && input_[position_] != '\'') {
                ++position_;
            }
            if (position_ == input_.length) {
                throw new ParseError(format("unterminated single-quoted string at byte %s", start));
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
        case '<':
            return Token(TokenKind.less, "<", start);
        case '>':
            return Token(TokenKind.greater, ">", start);
        case '(':
            return Token(TokenKind.leftParen, "(", start);
        case ')':
            return Token(TokenKind.rightParen, ")", start);
        case '[':
            return Token(TokenKind.leftBracket, "[", start);
        case ']':
            return Token(TokenKind.rightBracket, "]", start);
        case ',':
            return Token(TokenKind.comma, ",", start);
        default:
            throw new ParseError(format("unexpected byte '%s' at byte %s", c, start));
        }
    }

    private void skipSpace() {
        while (position_ < input_.length) {
            auto c = input_[position_];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                ++position_;
            } else {
                return;
            }
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

        if (position_ < input_.length && (input_[position_] == 'e' || input_[position_] == 'E')) {
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

private enum NumericKind {
    integer,
    floating,
}

private struct Numeric {
    NumericKind kind;
    BigInt integerValue;
    double floatValue;
}

private bool consumeDecimalIntPart(string s, ref size_t position) {
    if (position >= s.length || !asciiDigit(s[position])) {
        return false;
    }
    ++position;
    while (position < s.length) {
        if (asciiDigit(s[position])) {
            ++position;
            continue;
        }
        if (s[position] == '_' && position + 1 < s.length && asciiDigit(s[position + 1])) {
            position += 2;
            continue;
        }
        break;
    }
    return true;
}

private bool looksLikeYshInt(string input) {
    auto s = strip(input);
    if (s.length == 0) {
        return false;
    }
    size_t position;
    if (s[position] == '-') {
        ++position;
    }
    if (!consumeDecimalIntPart(s, position)) {
        return false;
    }
    return position == s.length;
}

private bool looksLikeYshFloat(string input) {
    auto s = strip(input);
    if (s.length == 0) {
        return false;
    }
    size_t position;
    if (s[position] == '-') {
        ++position;
    }
    if (!consumeDecimalIntPart(s, position)) {
        return false;
    }

    if (position < s.length && s[position] == '.') {
        ++position;
        if (!consumeDecimalIntPart(s, position)) {
            return false;
        }
    }

    if (position < s.length && (s[position] == 'e' || s[position] == 'E')) {
        ++position;
        if (position < s.length && (s[position] == '+' || s[position] == '-')) {
            ++position;
        }
        auto exponentStart = position;
        while (position < s.length && asciiDigit(s[position])) {
            ++position;
        }
        if (position == exponentStart) {
            return false;
        }
    }

    return position == s.length;
}

private Numeric convertToNumber(Value value) {
    final switch (value.kind) {
    case ValueKind.integer:
        return Numeric(NumericKind.integer, value.integerValue, 0.0);
    case ValueKind.floating:
        return Numeric(NumericKind.floating, BigInt(0), value.floatValue);
    case ValueKind.stringValue:
        if (looksLikeYshInt(value.stringValue)) {
            auto cleaned = strip(value.stringValue).replace("_", "");
            return Numeric(NumericKind.integer, BigInt(cleaned), 0.0);
        }
        if (looksLikeYshFloat(value.stringValue)) {
            auto cleaned = strip(value.stringValue).replace("_", "");
            return Numeric(NumericKind.floating, BigInt(0), to!double(cleaned));
        }
        throw new YshTypeError("expected Int, Float, or numeric Str");
    case ValueKind.nullValue:
    case ValueKind.boolean:
    case ValueKind.list:
    case ValueKind.dict:
        throw new YshTypeError(format("expected Int, Float, or numeric Str, got %s", value.kind));
    }
}

private BigInt convertToInt(Value value) {
    final switch (value.kind) {
    case ValueKind.integer:
        return value.integerValue;
    case ValueKind.stringValue:
        if (looksLikeYshInt(value.stringValue)) {
            return BigInt(strip(value.stringValue).replace("_", ""));
        }
        throw new YshTypeError("expected Int or integer Str");
    case ValueKind.nullValue:
    case ValueKind.boolean:
    case ValueKind.floating:
    case ValueKind.list:
    case ValueKind.dict:
        throw new YshTypeError("expected Int or integer Str");
    }
}

private double bigintToDouble(BigInt value) {
    return to!double(toDecimalString(value));
}

private Value numericBinary(string op, Value left, Value right) {
    auto a = convertToNumber(left);
    auto b = convertToNumber(right);

    if (a.kind == NumericKind.integer && b.kind == NumericKind.integer) {
        switch (op) {
        case "+":
            return Value.integer(a.integerValue + b.integerValue);
        case "-":
            return Value.integer(a.integerValue - b.integerValue);
        case "*":
            return Value.integer(a.integerValue * b.integerValue);
        case "/":
            if (b.integerValue == 0) {
                throw new YshError("Divide by zero");
            }
            return Value.floating(bigintToDouble(a.integerValue) / bigintToDouble(b.integerValue));
        default:
            assert(false, "unknown numeric operator");
        }
    }

    auto af = a.kind == NumericKind.integer ? bigintToDouble(a.integerValue) : a.floatValue;
    auto bf = b.kind == NumericKind.integer ? bigintToDouble(b.integerValue) : b.floatValue;
    switch (op) {
    case "+":
        return Value.floating(af + bf);
    case "-":
        return Value.floating(af - bf);
    case "*":
        return Value.floating(af * bf);
    case "/":
        if (bf == 0.0) {
            throw new YshError("Divide by zero");
        }
        return Value.floating(af / bf);
    default:
        assert(false, "unknown numeric operator");
    }
}

private BigInt exponent(BigInt base, BigInt power) {
    if (power < 0) {
        throw new YshError("Exponent can't be a negative number");
    }

    BigInt result = 1;
    BigInt factor = base;
    BigInt remaining = power;
    while (remaining != 0) {
        if ((remaining % 2) != 0) {
            result *= factor;
        }
        remaining /= 2;
        if (remaining != 0) {
            factor *= factor;
        }
    }
    return result;
}

private Value intBinary(string op, Value left, Value right) {
    auto a = convertToInt(left);
    auto b = convertToInt(right);

    switch (op) {
    case "//":
        if (b == 0) {
            throw new YshError("Divide by zero");
        }
        // D BigInt division, like YSH mops.Div, truncates toward zero.
        return Value.integer(a / b);
    case "%":
        if (b == 0) {
            throw new YshError("Divide by zero");
        }
        if (b < 0) {
            throw new YshError("Divisor can't be negative");
        }
        return Value.integer(a % b);
    case "**":
        return Value.integer(exponent(a, b));
    default:
        assert(false, "unknown integer operator");
    }
}

private Value concat(Value left, Value right) {
    if (left.kind == ValueKind.stringValue && right.kind == ValueKind.stringValue) {
        return Value.str(left.stringValue ~ right.stringValue);
    }
    if (left.kind == ValueKind.list && right.kind == ValueKind.list) {
        Value[] items = left.listValue.dup;
        items ~= right.listValue;
        return Value.list(items);
    }
    if (left.kind == ValueKind.dict && right.kind == ValueKind.dict) {
        Value[string] fields;
        foreach (key, value; left.dictValue) {
            fields[key] = value;
        }
        foreach (key, value; right.dictValue) {
            fields[key] = value;
        }
        return Value.dict(fields);
    }
    throw new YshTypeError("Expected Str ++ Str, List ++ List, or Dict ++ Dict");
}

private bool numericCompare(string op, Value left, Value right) {
    auto a = convertToNumber(left);
    auto b = convertToNumber(right);

    if (a.kind == NumericKind.integer && b.kind == NumericKind.integer) {
        switch (op) {
        case "<":
            return a.integerValue < b.integerValue;
        case ">":
            return a.integerValue > b.integerValue;
        case "<=":
            return a.integerValue <= b.integerValue;
        case ">=":
            return a.integerValue >= b.integerValue;
        default:
            assert(false, "unknown comparison operator");
        }
    }

    auto af = a.kind == NumericKind.integer ? bigintToDouble(a.integerValue) : a.floatValue;
    auto bf = b.kind == NumericKind.integer ? bigintToDouble(b.integerValue) : b.floatValue;
    switch (op) {
    case "<":
        return af < bf;
    case ">":
        return af > bf;
    case "<=":
        return af <= bf;
    case ">=":
        return af >= bf;
    default:
        assert(false, "unknown comparison operator");
    }
}

abstract class Expr {
    abstract Value eval();
}

private class LiteralExpr : Expr {
    private Value value_;

    this(Value value) {
        value_ = value;
    }

    override Value eval() {
        return value_;
    }
}

private class ListExpr : Expr {
    private Expr[] items_;

    this(Expr[] items) {
        items_ = items;
    }

    override Value eval() {
        Value[] values;
        foreach (item; items_) {
            values ~= item.eval();
        }
        return Value.list(values);
    }
}

private class UnaryExpr : Expr {
    private string op_;
    private Expr child_;

    this(string op, Expr child) {
        op_ = op;
        child_ = child;
    }

    override Value eval() {
        auto value = child_.eval();
        switch (op_) {
        case "+":
            auto number = convertToNumber(value);
            return number.kind == NumericKind.integer
                ? Value.integer(number.integerValue)
                : Value.floating(number.floatValue);
        case "-":
            auto number = convertToNumber(value);
            return number.kind == NumericKind.integer
                ? Value.integer(-number.integerValue)
                : Value.floating(-number.floatValue);
        case "not":
            return Value.boolean(!toBool(value));
        default:
            assert(false, "unknown unary operator");
        }
    }
}

private class BinaryExpr : Expr {
    private string op_;
    private Expr left_;
    private Expr right_;

    this(string op, Expr left, Expr right) {
        op_ = op;
        left_ = left;
        right_ = right;
    }

    override Value eval() {
        auto left = left_.eval();

        if (op_ == "and") {
            return toBool(left) ? right_.eval() : left;
        }
        if (op_ == "or") {
            return toBool(left) ? left : right_.eval();
        }

        auto right = right_.eval();
        switch (op_) {
        case "+":
        case "-":
        case "*":
        case "/":
            return numericBinary(op_, left, right);
        case "//":
        case "%":
        case "**":
            return intBinary(op_, left, right);
        case "++":
            return concat(left, right);
        default:
            assert(false, "unknown binary operator");
        }
    }
}

private class CompareExpr : Expr {
    private Expr left_;
    private string[] operators_;
    private Expr[] comparators_;

    this(Expr left, string[] operators, Expr[] comparators) {
        left_ = left;
        operators_ = operators;
        comparators_ = comparators;
    }

    override Value eval() {
        Value left = left_.eval();
        foreach (index, op; operators_) {
            Value right = comparators_[index].eval();
            bool result;
            switch (op) {
            case "<":
            case ">":
            case "<=":
            case ">=":
                result = numericCompare(op, left, right);
                break;
            case "===":
                result = exactlyEqual(left, right);
                break;
            case "!==":
                result = !exactlyEqual(left, right);
                break;
            default:
                assert(false, "unknown comparison operator");
            }
            if (!result) {
                return Value.boolean(false);
            }
            left = right;
        }
        return Value.boolean(true);
    }
}

private class Parser {
    private Lexer lexer_;
    private Token current_;

    this(string input) {
        lexer_ = new Lexer(input);
        current_ = lexer_.next();
    }

    Expr parse() {
        Expr result = parseOr();
        if (current_.kind != TokenKind.eof) {
            throw new ParseError(format("unexpected '%s' at byte %s", current_.text, current_.offset));
        }
        return result;
    }

    private void advance() {
        current_ = lexer_.next();
    }

    private Expr parseOr() {
        Expr left = parseAnd();
        while (current_.kind == TokenKind.orKeyword) {
            auto op = current_.text;
            advance();
            left = new BinaryExpr(op, left, parseAnd());
        }
        return left;
    }

    private Expr parseAnd() {
        Expr left = parseNot();
        while (current_.kind == TokenKind.andKeyword) {
            auto op = current_.text;
            advance();
            left = new BinaryExpr(op, left, parseNot());
        }
        return left;
    }

    private Expr parseNot() {
        if (current_.kind == TokenKind.notKeyword) {
            auto op = current_.text;
            advance();
            return new UnaryExpr(op, parseNot());
        }
        return parseComparison();
    }

    private Expr parseComparison() {
        Expr left = parseAdditive();
        string[] operators;
        Expr[] comparators;

        while (isComparison(current_.kind)) {
            operators ~= current_.text;
            advance();
            comparators ~= parseAdditive();
        }

        if (operators.length == 0) {
            return left;
        }
        return new CompareExpr(left, operators, comparators);
    }

    private bool isComparison(TokenKind kind) {
        switch (kind) {
        case TokenKind.less:
        case TokenKind.greater:
        case TokenKind.lessEqual:
        case TokenKind.greaterEqual:
        case TokenKind.tripleEqual:
        case TokenKind.notDoubleEqual:
            return true;
        default:
            return false;
        }
    }

    private Expr parseAdditive() {
        Expr left = parseMultiplicative();
        while (current_.kind == TokenKind.plus || current_.kind == TokenKind.minus ||
                current_.kind == TokenKind.plusPlus) {
            auto op = current_.text;
            advance();
            left = new BinaryExpr(op, left, parseMultiplicative());
        }
        return left;
    }

    private Expr parseMultiplicative() {
        Expr left = parseFactor();
        while (current_.kind == TokenKind.star || current_.kind == TokenKind.slash ||
                current_.kind == TokenKind.slashSlash || current_.kind == TokenKind.percent) {
            auto op = current_.text;
            advance();
            left = new BinaryExpr(op, left, parseFactor());
        }
        return left;
    }

    // Mirrors grammar.pgen2: factor -> ('+'|'-'|'~') factor | power.
    private Expr parseFactor() {
        if (current_.kind == TokenKind.plus || current_.kind == TokenKind.minus) {
            auto op = current_.text;
            advance();
            return new UnaryExpr(op, parseFactor());
        }
        return parsePower();
    }

    // Mirrors grammar.pgen2: power -> atom trailer* ['**' factor].
    private Expr parsePower() {
        Expr left = parseAtom();
        if (current_.kind == TokenKind.starStar) {
            auto op = current_.text;
            advance();
            return new BinaryExpr(op, left, parseFactor());
        }
        return left;
    }

    private Expr parseAtom() {
        auto token = current_;
        switch (token.kind) {
        case TokenKind.nullKeyword:
            advance();
            return new LiteralExpr(Value.nullValue());
        case TokenKind.trueKeyword:
            advance();
            return new LiteralExpr(Value.boolean(true));
        case TokenKind.falseKeyword:
            advance();
            return new LiteralExpr(Value.boolean(false));
        case TokenKind.integer:
            advance();
            return new LiteralExpr(Value.integer(BigInt(token.text)));
        case TokenKind.floating:
            advance();
            return new LiteralExpr(Value.floating(to!double(token.text.replace("_", ""))));
        case TokenKind.stringValue:
            advance();
            return new LiteralExpr(Value.str(token.text));
        case TokenKind.leftParen:
            advance();
            Expr inside = parseOr();
            require(TokenKind.rightParen, ")");
            return inside;
        case TokenKind.leftBracket:
            return parseList();
        default:
            throw new ParseError(format("expected expression at byte %s, got '%s'", token.offset, token.text));
        }
    }

    private Expr parseList() {
        require(TokenKind.leftBracket, "[");
        Expr[] items;
        if (current_.kind != TokenKind.rightBracket) {
            while (true) {
                items ~= parseOr();
                if (current_.kind != TokenKind.comma) {
                    break;
                }
                advance();
                if (current_.kind == TokenKind.rightBracket) {
                    break;
                }
            }
        }
        require(TokenKind.rightBracket, "]");
        return new ListExpr(items);
    }

    private void require(TokenKind kind, string spelling) {
        if (current_.kind != kind) {
            throw new ParseError(format("expected '%s' at byte %s", spelling, current_.offset));
        }
        advance();
    }
}

Value evaluate(string source) {
    auto parser = new Parser(source);
    return parser.parse().eval();
}

unittest {
    import yshd.value : repr;

    assert(repr(evaluate("1 + 2 * 3")) == "7");
    assert(repr(evaluate("-2 ** 2")) == "-4");
    assert(repr(evaluate("(-2) ** 2")) == "4");
    assert(repr(evaluate("7 / 2")) == "3.5");
    assert(repr(evaluate("-7 // 2")) == "-3");
    assert(repr(evaluate("-7 % 2")) == "-1");
    assert(repr(evaluate("2 ** 10")) == "1024");
    assert(repr(evaluate("'a' ++ 'b'")) == "\"ab\"");
    assert(repr(evaluate("[1, 2] ++ [3]")) == "[1, 2, 3]");
    assert(repr(evaluate("0 or 42")) == "42");
    assert(repr(evaluate("1 and 42")) == "42");
    assert(repr(evaluate("not []")) == "true");
    assert(repr(evaluate("1 < 2 < 3")) == "true");
    assert(repr(evaluate("1 === 1")) == "true");
    assert(repr(evaluate("1 !== '1'")) == "true");
    assert(repr(evaluate("'40' + 2")) == "42");
    assert(repr(evaluate("+'3_000'")) == "3000");
    assert(repr(evaluate("0 and (1 / 0)")) == "0");
    assert(repr(evaluate("1 or (1 / 0)")) == "1");

    bool rejectedFloatEquality;
    try {
        evaluate("1.0 === 1.0");
    } catch (YshTypeError error) {
        rejectedFloatEquality = true;
    }
    assert(rejectedFloatEquality);

    bool rejectedNegativeDivisor;
    try {
        evaluate("7 % -2");
    } catch (YshError error) {
        rejectedNegativeDivisor = true;
    }
    assert(rejectedNegativeDivisor);
}
