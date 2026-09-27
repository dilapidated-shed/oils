module yshd.expr;

import std.bigint : BigInt, toDecimalString;
import std.conv : to;
import std.format : format;
import std.string : replace, strip;

import yshd.lexer : Lexer, Token, TokenKind, asciiDigit;
import yshd.state : Memory;
import yshd.value : Value, ValueKind, YshError, YshTypeError, exactlyEqual, toBool;

class ParseError : YshError {
    this(string message) {
        super(message);
    }
}

private enum CompareOp {
    less,
    greater,
    lessEqual,
    greaterEqual,
    exactEqual,
    notExactEqual,
    contains,
    notContains,
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
    case ValueKind.sliceValue:
    case ValueKind.rangeValue:
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
    case ValueKind.sliceValue:
    case ValueKind.rangeValue:
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
    abstract Value eval(Memory mem);
}

private class LiteralExpr : Expr {
    private Value value_;

    this(Value value) {
        value_ = value;
    }

    override Value eval(Memory mem) {
        return value_;
    }
}


private class VariableExpr : Expr {
    private string name_;

    this(string name) {
        name_ = name;
    }

    override Value eval(Memory mem) {
        return mem.get(name_);
    }

    Value evalLeft(Memory mem, AssignmentScope assignmentScope) {
        return assignmentScope == AssignmentScope.global
            ? mem.getGlobal(name_)
            : mem.getLocal(name_);
    }
}

private class DictExpr : Expr {
    private string[] keys_;
    private Expr[] values_;

    this(string[] keys, Expr[] values) {
        keys_ = keys;
        values_ = values;
    }

    override Value eval(Memory mem) {
        Value[string] fields;
        foreach (index, key; keys_) {
            fields[key] = values_[index].eval(mem);
        }
        return Value.dict(fields);
    }
}

private long listIndex(Value index) {
    auto integer = convertToInt(index);
    try {
        return to!long(toDecimalString(integer));
    } catch (Exception error) {
        throw new YshTypeError("List index should fit in an Int");
    }
}

private string dictKey(Value index) {
    if (index.kind != ValueKind.stringValue) {
        throw new YshTypeError("Dict index should be Str");
    }
    return index.stringValue;
}

private class SubscriptExpr : Expr {
    private Expr object_;
    private Expr index_;

    this(Expr object, Expr index) {
        object_ = object;
        index_ = index;
    }

    override Value eval(Memory mem) {
        auto object = object_.eval(mem);
        auto index = index_.eval(mem);

        final switch (object.kind) {
        case ValueKind.list:
            auto i = listIndex(index);
            if (i < 0) {
                i += cast(long)object.listValue.length;
            }
            if (i < 0 || i >= object.listValue.length) {
                throw new YshError("List index out of range");
            }
            return object.listValue[cast(size_t)i];
        case ValueKind.dict:
            auto key = dictKey(index);
            auto found = key in object.dictValue;
            if (found is null) {
                throw new YshError(format("Dict key not found: '%s'", key));
            }
            return *found;
        case ValueKind.nullValue:
        case ValueKind.boolean:
        case ValueKind.integer:
        case ValueKind.floating:
        case ValueKind.stringValue:
        case ValueKind.sliceValue:
        case ValueKind.rangeValue:
            throw new YshTypeError("obj[index] expected List or Dict");
        }
    }

    void assign(Memory mem, Value value) {
        auto object = object_.eval(mem);
        auto index = index_.eval(mem);

        final switch (object.kind) {
        case ValueKind.list:
            auto i = listIndex(index);
            if (i < 0) {
                i += cast(long)object.listValue.length;
            }
            if (i < 0 || i >= object.listValue.length) {
                throw new YshError("index out of range");
            }
            object.listValue[cast(size_t)i] = value;
            return;
        case ValueKind.dict:
            object.dictValue[dictKey(index)] = value;
            return;
        case ValueKind.nullValue:
        case ValueKind.boolean:
        case ValueKind.integer:
        case ValueKind.floating:
        case ValueKind.stringValue:
        case ValueKind.sliceValue:
        case ValueKind.rangeValue:
            throw new YshTypeError("obj[index] expected List or Dict");
        }
    }
}

private class AttributeExpr : Expr {
    private Expr object_;
    private string name_;

    this(Expr object, string name) {
        object_ = object;
        name_ = name;
    }

    override Value eval(Memory mem) {
        auto object = object_.eval(mem);
        if (object.kind != ValueKind.dict) {
            throw new YshTypeError("attribute lookup expected Dict in this translated slice");
        }
        auto found = name_ in object.dictValue;
        if (found is null) {
            throw new YshError(format("Dict key not found: '%s'", name_));
        }
        return *found;
    }

    void assign(Memory mem, Value value) {
        auto object = object_.eval(mem);
        if (object.kind != ValueKind.dict) {
            throw new YshTypeError("attribute assignment expected Dict in this translated slice");
        }
        object.dictValue[name_] = value;
    }
}


private Value evalLeftObject(Expr expression, Memory mem,
        AssignmentScope assignmentScope) {
    if (auto variable = cast(VariableExpr)expression) {
        return variable.evalLeft(mem, assignmentScope);
    }

    if (auto subscript = cast(SubscriptExpr)expression) {
        auto object = evalLeftObject(subscript.object_, mem, assignmentScope);
        auto index = subscript.index_.eval(mem);

        final switch (object.kind) {
        case ValueKind.list:
            auto i = listIndex(index);
            if (i < 0) {
                i += cast(long)object.listValue.length;
            }
            if (i < 0 || i >= object.listValue.length) {
                throw new YshError("List index out of range");
            }
            return object.listValue[cast(size_t)i];
        case ValueKind.dict:
            auto key = dictKey(index);
            auto found = key in object.dictValue;
            if (found is null) {
                throw new YshError(format("Dict key not found: '%s'", key));
            }
            return *found;
        case ValueKind.nullValue:
        case ValueKind.boolean:
        case ValueKind.integer:
        case ValueKind.floating:
        case ValueKind.stringValue:
        case ValueKind.sliceValue:
        case ValueKind.rangeValue:
            throw new YshTypeError("obj[index] expected List or Dict");
        }
    }

    if (auto attribute = cast(AttributeExpr)expression) {
        auto object = evalLeftObject(attribute.object_, mem, assignmentScope);
        if (object.kind != ValueKind.dict) {
            throw new YshTypeError("attribute lookup expected Dict");
        }
        auto found = attribute.name_ in object.dictValue;
        if (found is null) {
            throw new YshError(format(
                "Dict key not found: '%s'", attribute.name_));
        }
        return *found;
    }

    throw new YshError("invalid left side for setvar/setglobal");
}

private class ListExpr : Expr {
    private Expr[] items_;

    this(Expr[] items) {
        items_ = items;
    }

    override Value eval(Memory mem) {
        Value[] values;
        foreach (item; items_) {
            values ~= item.eval(mem);
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

    override Value eval(Memory mem) {
        auto value = child_.eval(mem);
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

    override Value eval(Memory mem) {
        auto left = left_.eval(mem);

        if (op_ == "and") {
            return toBool(left) ? right_.eval(mem) : left;
        }
        if (op_ == "or") {
            return toBool(left) ? left : right_.eval(mem);
        }

        auto right = right_.eval(mem);
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
    private CompareOp[] operators_;
    private Expr[] comparators_;

    this(Expr left, CompareOp[] operators, Expr[] comparators) {
        left_ = left;
        operators_ = operators;
        comparators_ = comparators;
    }

    override Value eval(Memory mem) {
        Value left = left_.eval(mem);
        foreach (index, op; operators_) {
            Value right = comparators_[index].eval(mem);
            bool result;
            final switch (op) {
            case CompareOp.less:
                result = numericCompare("<", left, right);
                break;
            case CompareOp.greater:
                result = numericCompare(">", left, right);
                break;
            case CompareOp.lessEqual:
                result = numericCompare("<=", left, right);
                break;
            case CompareOp.greaterEqual:
                result = numericCompare(">=", left, right);
                break;
            case CompareOp.exactEqual:
                result = exactlyEqual(left, right);
                break;
            case CompareOp.notExactEqual:
                result = !exactlyEqual(left, right);
                break;
            case CompareOp.contains:
                if (right.kind != ValueKind.dict) {
                    throw new YshTypeError("RHS of 'in' should be Dict");
                }
                if (left.kind != ValueKind.stringValue) {
                    throw new YshTypeError("LHS of 'in' should be Str");
                }
                result = (left.stringValue in right.dictValue) !is null;
                break;
            case CompareOp.notContains:
                if (right.kind != ValueKind.dict) {
                    throw new YshTypeError("RHS of 'not in' should be Dict");
                }
                if (left.kind != ValueKind.stringValue) {
                    throw new YshTypeError("LHS of 'not in' should be Str");
                }
                result = (left.stringValue in right.dictValue) is null;
                break;
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
        CompareOp[] operators;
        Expr[] comparators;

        while (isComparison(current_.kind)) {
            if (current_.kind == TokenKind.notKeyword) {
                advance();
                if (current_.kind != TokenKind.inKeyword) {
                    throw new ParseError(format("expected 'in' at byte %s", current_.offset));
                }
                operators ~= CompareOp.notContains;
                advance();
            } else {
                switch (current_.kind) {
                case TokenKind.less:
                    operators ~= CompareOp.less;
                    break;
                case TokenKind.greater:
                    operators ~= CompareOp.greater;
                    break;
                case TokenKind.lessEqual:
                    operators ~= CompareOp.lessEqual;
                    break;
                case TokenKind.greaterEqual:
                    operators ~= CompareOp.greaterEqual;
                    break;
                case TokenKind.tripleEqual:
                    operators ~= CompareOp.exactEqual;
                    break;
                case TokenKind.notDoubleEqual:
                    operators ~= CompareOp.notExactEqual;
                    break;
                case TokenKind.inKeyword:
                    operators ~= CompareOp.contains;
                    break;
                default:
                    throw new ParseError("invalid comparison operator");
                }
                advance();
            }
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
        case TokenKind.inKeyword:
        case TokenKind.notKeyword:
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

        while (current_.kind == TokenKind.leftBracket || current_.kind == TokenKind.dot) {
            if (current_.kind == TokenKind.leftBracket) {
                advance();
                auto index = parseOr();
                require(TokenKind.rightBracket, "]");
                left = new SubscriptExpr(left, index);
            } else {
                advance();
                if (current_.kind != TokenKind.name) {
                    throw new ParseError(format("expected attribute name at byte %s", current_.offset));
                }
                auto name = current_.text;
                advance();
                left = new AttributeExpr(left, name);
            }
        }

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
        case TokenKind.name:
            advance();
            return new VariableExpr(token.text);
        case TokenKind.leftParen:
            advance();
            Expr inside = parseOr();
            require(TokenKind.rightParen, ")");
            return inside;
        case TokenKind.leftBracket:
            return parseList();
        case TokenKind.leftBrace:
            return parseDict();
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

    private Expr parseDict() {
        require(TokenKind.leftBrace, "{");
        string[] keys;
        Expr[] values;

        if (current_.kind != TokenKind.rightBrace) {
            while (true) {
                string key;
                Expr value;

                if (current_.kind == TokenKind.name) {
                    key = current_.text;
                    advance();
                    if (current_.kind == TokenKind.colon) {
                        advance();
                        value = parseOr();
                    } else {
                        value = new VariableExpr(key);
                    }
                } else if (current_.kind == TokenKind.stringValue) {
                    key = current_.text;
                    advance();
                    require(TokenKind.colon, ":");
                    value = parseOr();
                } else {
                    throw new ParseError(format(
                        "expected Dict key at byte %s", current_.offset));
                }

                keys ~= key;
                values ~= value;

                if (current_.kind != TokenKind.comma) {
                    break;
                }
                advance();
                if (current_.kind == TokenKind.rightBrace) {
                    break;
                }
            }
        }

        require(TokenKind.rightBrace, "}");
        return new DictExpr(keys, values);
    }

    private void require(TokenKind kind, string spelling) {
        if (current_.kind != kind) {
            throw new ParseError(format("expected '%s' at byte %s", spelling, current_.offset));
        }
        advance();
    }
}

enum AssignmentScope {
    local,
    global,
}

abstract class ResolvedPlace {
    abstract void assign(Value value);
}

private class NameResolvedPlace : ResolvedPlace {
    private Memory mem_;
    private string name_;
    private AssignmentScope assignmentScope_;

    this(Memory mem, string name, AssignmentScope assignmentScope) {
        mem_ = mem;
        name_ = name;
        assignmentScope_ = assignmentScope;
    }

    override void assign(Value value) {
        if (assignmentScope_ == AssignmentScope.global) {
            mem_.setGlobal(name_, value);
        } else {
            mem_.setVar(name_, value);
        }
    }
}

private class ContainerResolvedPlace : ResolvedPlace {
    private Value object_;
    private Value index_;

    this(Value object, Value index) {
        object_ = object;
        index_ = index;
    }

    override void assign(Value value) {
        final switch (object_.kind) {
        case ValueKind.list:
            auto i = listIndex(index_);
            if (i < 0) {
                i += cast(long)object_.listValue.length;
            }
            if (i < 0 || i >= object_.listValue.length) {
                throw new YshError("index out of range");
            }
            object_.listValue[cast(size_t)i] = value;
            return;
        case ValueKind.dict:
            object_.dictValue[dictKey(index_)] = value;
            return;
        case ValueKind.nullValue:
        case ValueKind.boolean:
        case ValueKind.integer:
        case ValueKind.floating:
        case ValueKind.stringValue:
        case ValueKind.sliceValue:
        case ValueKind.rangeValue:
            throw new YshTypeError("obj[index] expected List or Dict");
        }
    }
}

ResolvedPlace resolvePlace(string source, Memory mem,
        AssignmentScope assignmentScope = AssignmentScope.local) {
    auto parser = new Parser(source);
    auto target = parser.parse();

    if (auto variable = cast(VariableExpr)target) {
        return new NameResolvedPlace(mem, variable.name_, assignmentScope);
    }

    if (auto subscript = cast(SubscriptExpr)target) {
        auto object = evalLeftObject(
            subscript.object_, mem, assignmentScope);
        auto index = subscript.index_.eval(mem);
        return new ContainerResolvedPlace(object, index);
    }

    if (auto attribute = cast(AttributeExpr)target) {
        auto object = evalLeftObject(
            attribute.object_, mem, assignmentScope);
        return new ContainerResolvedPlace(object, Value.str(attribute.name_));
    }

    throw new YshError(
        "assignment target must be a variable, subscript, or attribute");
}

void assignPlace(string source, Value value, Memory mem,
        AssignmentScope assignmentScope = AssignmentScope.local) {
    resolvePlace(source, mem, assignmentScope).assign(value);
}

Value evaluate(string source) {
    return evaluate(source, new Memory());
}

Value evaluate(string source, Memory mem) {
    auto parser = new Parser(source);
    return parser.parse().eval(mem);
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

    auto mem = new Memory();
    mem.declareLocal("x", Value.integer(40));
    assert(repr(evaluate("x + 2", mem)) == "42");

    mem.declareLocal("name", Value.str("foo"));
    assert(repr(evaluate("{name, other: 2}", mem)) == "{\"name\": \"foo\", \"other\": 2}" ||
           repr(evaluate("{name, other: 2}", mem)) == "{\"other\": 2, \"name\": \"foo\"}");
    assert(repr(evaluate("{answer: 42}.answer", mem)) == "42");
    assert(repr(evaluate("[10, 20, 30][1]", mem)) == "20");
    assert(repr(evaluate("'answer' in {answer: 42}", mem)) == "true");
    assert(repr(evaluate("'missing' not in {answer: 42}", mem)) == "true");

    mem.declareLocal("items", evaluate("[1, 2, 3]", mem));
    assignPlace("items[1]", Value.integer(42), mem);
    assert(repr(mem.get("items")) == "[1, 42, 3]");

    mem.declareLocal("record", evaluate("{old: 1}", mem));
    assignPlace("record.new", Value.integer(2), mem);
    assert(repr(evaluate("record.new", mem)) == "2");

    assignPlace("x", Value.integer(99), mem);
    assert(repr(evaluate("x", mem)) == "99");
}
