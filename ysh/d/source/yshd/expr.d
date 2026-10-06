module yshd.expr;

import std.bigint : BigInt, toDecimalString;
import std.conv : to;
import std.algorithm.mutation : reverse;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.file : SpanMode, dirEntries;
import std.format : format;
import std.path : baseName, dirName;
import std.string : endsWith, indexOf, lastIndexOf, replace, split,
    startsWith, strip, stripLeft, stripRight;
import std.uni : toLower, toUpper;

import yshd.lexer : Lexer, Token, TokenKind, asciiDigit;
import yshd.func_proc : YshFunction;
import yshd.state : Memory;
import yshd.value : Value, ValueKind, YshDict, YshError, YshTypeError,
    exactlyEqual, kindName, stringify, toBool;

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
    case ValueKind.functionValue:
    case ValueKind.procValue:
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
    case ValueKind.functionValue:
    case ValueKind.procValue:
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
    case "&":
        return Value.integer(a & b);
    case "|":
        return Value.integer(a | b);
    case "^":
        return Value.integer(a ^ b);
    case "<<":
    case ">>":
        if (b < 0) {
            throw new YshError(
                op == "<<" ? "Can't left shift by negative number"
                           : "Can't right shift by negative number");
        }
        long count;
        try {
            count = to!long(toDecimalString(b));
        } catch (Exception error) {
            throw new YshError("shift count is too large");
        }
        return Value.integer(
            op == "<<" ? (a << cast(size_t)count)
                       : (a >> cast(size_t)count));
    default:
        assert(false, "unknown integer operator");
    }
}

private Value concat(Value left, Value right) {
    if (left.kind == ValueKind.stringValue && right.kind == ValueKind.stringValue) {
        return Value.str(left.stringValue ~ right.stringValue);
    }
    if (left.kind == ValueKind.list && right.kind == ValueKind.list) {
        Value[] items = left.listValue.items.dup;
        items ~= right.listValue.items;
        return Value.list(items);
    }
    if (left.kind == ValueKind.dict && right.kind == ValueKind.dict) {
        auto result = Value.dict();
        foreach (key, value; left.dictValue) {
            result.dictValue.set(key, value);
        }
        foreach (key, value; right.dictValue) {
            result.dictValue.set(key, value);
        }
        return result;
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


private class DoubleQuotedExpr : Expr {
    private string content_;

    this(string content) {
        content_ = content;
    }

    override Value eval(Memory mem) {
        import yshd.program : evaluateDoubleQuotedExpression;
        return Value.str(evaluateDoubleQuotedExpression(content_, mem));
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
    private Expr[] keys_;
    private Expr[] values_;

    this(Expr[] keys, Expr[] values) {
        keys_ = keys;
        values_ = values;
    }

    override Value eval(Memory mem) {
        auto result = Value.dict();
        foreach (index, keyExpr; keys_) {
            auto key = dictKey(keyExpr.eval(mem));
            result.dictValue.set(key, values_[index].eval(mem));
        }
        return result;
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


private long bigIntToLong(BigInt integer, string description) {
    try {
        return to!long(toDecimalString(integer));
    } catch (Exception error) {
        throw new YshTypeError(description);
    }
}

private long normalizeIndex(long index, size_t length) {
    auto n = cast(long)length;
    return index < 0 ? index + n : index;
}

private long normalizeSliceBound(long bound, size_t length) {
    auto n = cast(long)length;
    auto result = bound < 0 ? bound + n : bound;
    if (result < 0) {
        return 0;
    }
    if (result > n) {
        return n;
    }
    return result;
}

private Value subscriptGet(Value object, Value index) {
    final switch (object.kind) {
    case ValueKind.stringValue:
        if (index.kind == ValueKind.sliceValue) {
            auto lower = index.sliceHasLower
                ? normalizeSliceBound(index.sliceLower, object.stringValue.length)
                : 0;
            auto upper = index.sliceHasUpper
                ? normalizeSliceBound(index.sliceUpper, object.stringValue.length)
                : cast(long)object.stringValue.length;
            if (upper < lower) {
                upper = lower;
            }
            return Value.str(object.stringValue[
                cast(size_t)lower .. cast(size_t)upper]);
        }

        auto i = normalizeIndex(
            bigIntToLong(convertToInt(index), "Str index expected Int"),
            object.stringValue.length);
        if (i < 0 || i >= object.stringValue.length) {
            throw new YshError("index out of range");
        }
        return Value.str(object.stringValue[
            cast(size_t)i .. cast(size_t)i + 1]);

    case ValueKind.list:
        if (index.kind == ValueKind.sliceValue) {
            auto lower = index.sliceHasLower
                ? normalizeSliceBound(index.sliceLower, object.listValue.length)
                : 0;
            auto upper = index.sliceHasUpper
                ? normalizeSliceBound(index.sliceUpper, object.listValue.length)
                : cast(long)object.listValue.length;
            if (upper < lower) {
                upper = lower;
            }
            return Value.list(object.listValue.items[
                cast(size_t)lower .. cast(size_t)upper].dup);
        }

        auto i = normalizeIndex(listIndex(index), object.listValue.length);
        if (i < 0 || i >= object.listValue.length) {
            throw new YshError("List index out of range");
        }
        return object.listValue.items[cast(size_t)i];

    case ValueKind.dict:
        auto key = dictKey(index);
        auto found = object.dictValue.find(key);
        if (found is null) {
            throw new YshError(format("Dict key not found: '%s'", key));
        }
        return *found;

    case ValueKind.nullValue:
    case ValueKind.boolean:
    case ValueKind.integer:
    case ValueKind.floating:
    case ValueKind.sliceValue:
    case ValueKind.rangeValue:
    case ValueKind.functionValue:
    case ValueKind.procValue:
        throw new YshTypeError("obj[index] expected Str, List, or Dict");
    }
}

private class SliceExpr : Expr {
    private Expr lower_;
    private Expr upper_;

    this(Expr lower, Expr upper) {
        lower_ = lower;
        upper_ = upper;
    }

    override Value eval(Memory mem) {
        bool hasLower = lower_ !is null;
        bool hasUpper = upper_ !is null;
        long lower;
        long upper;

        if (hasLower) {
            lower = bigIntToLong(
                convertToInt(lower_.eval(mem)), "Slice begin should be Int");
        }
        if (hasUpper) {
            upper = bigIntToLong(
                convertToInt(upper_.eval(mem)), "Slice end should be Int");
        }
        return Value.slice(hasLower, lower, hasUpper, upper);
    }
}

private class RangeExpr : Expr {
    private Expr lower_;
    private Expr upper_;
    private bool closed_;

    this(Expr lower, Expr upper, bool closed) {
        lower_ = lower;
        upper_ = upper;
        closed_ = closed;
    }

    override Value eval(Memory mem) {
        auto lower = bigIntToLong(
            convertToInt(lower_.eval(mem)), "Range begin should be Int");
        auto upper = bigIntToLong(
            convertToInt(upper_.eval(mem)), "Range end should be Int");
        if (closed_) {
            ++upper;
        }
        return Value.range(lower, upper);
    }
}

private class SubscriptExpr : Expr {
    private Expr object_;
    private Expr index_;

    this(Expr object, Expr index) {
        object_ = object;
        index_ = index;
    }

    override Value eval(Memory mem) {
        return subscriptGet(object_.eval(mem), index_.eval(mem));
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
            object.listValue.items[cast(size_t)i] = value;
            return;
        case ValueKind.dict:
            object.dictValue.set(dictKey(index), value);
            return;
        case ValueKind.nullValue:
        case ValueKind.boolean:
        case ValueKind.integer:
        case ValueKind.floating:
        case ValueKind.stringValue:
        case ValueKind.sliceValue:
        case ValueKind.rangeValue:
        case ValueKind.functionValue:
        case ValueKind.procValue:
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
        if (object.kind == ValueKind.dict) {
            auto found = object.dictValue.find(name_);
            if (found !is null) {
                return *found;
            }
        }
        if (valueMethodExists(object.kind, name_)) {
            return Value.callable(new YshBoundMethod(object, name_, false));
        }
        if (object.kind == ValueKind.dict) {
            throw new YshError(format("Dict key not found: '%s'", name_));
        }
        throw new YshTypeError("value has no attribute '" ~ name_ ~ "'");
    }

    void assign(Memory mem, Value value) {
        auto object = object_.eval(mem);
        if (object.kind != ValueKind.dict) {
            throw new YshTypeError("attribute assignment expected Dict in this translated slice");
        }
        object.dictValue.set(name_, value);
    }
}

private struct PositionalCallArgument {
    Expr expression;
    bool spread;
}

private struct NamedCallArgument {
    string name;
    Expr expression;
    bool spread;
}

private bool builtinFunctionName(string name) {
    switch (name) {
    case "identity":
    case "len":
    case "abs":
    case "max":
    case "min":
    case "get":
    case "getVar":
    case "type":
    case "int":
    case "float":
    case "str":
    case "bool":
    case "glob":
    case "list":
    case "keys":
    case "values":
    case "strcmp":
        return true;
    default:
        return false;
    }
}

private Value callBuiltinFunction(string name, Value[] arguments,
        YshDict namedArguments, Memory mem) {
    if (namedArguments !is null && namedArguments.length != 0) {
        throw new YshTypeError(format("%s() does not accept named arguments yet", name));
    }

    switch (name) {
    case "identity":
        if (arguments.length != 1) {
            throw new YshTypeError("identity() expects one argument");
        }
        return arguments[0];

    case "len":
        if (arguments.length != 1) {
            throw new YshTypeError("len() expects one argument");
        }
        switch (arguments[0].kind) {
        case ValueKind.stringValue:
            return Value.integer(cast(long)arguments[0].stringValue.length);
        case ValueKind.list:
            return Value.integer(cast(long)arguments[0].listValue.length);
        case ValueKind.dict:
            return Value.integer(cast(long)arguments[0].dictValue.length);
        default:
            throw new YshTypeError("len() expects Str, List, or Dict");
        }

    case "abs":
        if (arguments.length != 1) {
            throw new YshTypeError("abs() expects one argument");
        }
        auto number = convertToNumber(arguments[0]);
        if (number.kind == NumericKind.integer) {
            return Value.integer(number.integerValue < 0
                ? -number.integerValue : number.integerValue);
        }
        return Value.floating(number.floatValue < 0.0
            ? -number.floatValue : number.floatValue);

    case "max":
    case "min":
        if (arguments.length == 0) {
            throw new YshTypeError(name ~ "() expects at least one argument");
        }
        auto best = arguments[0];
        foreach (candidate; arguments[1 .. $]) {
            auto replaceBest = name == "max"
                ? numericCompare(">", candidate, best)
                : numericCompare("<", candidate, best);
            if (replaceBest) {
                best = candidate;
            }
        }
        return best;

    case "get":
        if (arguments.length < 2 || arguments.length > 3) {
            throw new YshTypeError("get() expects Dict, key, and optional fallback");
        }
        if (arguments[0].kind != ValueKind.dict ||
                arguments[1].kind != ValueKind.stringValue) {
            throw new YshTypeError("get() expects Dict and Str key");
        }
        auto found = arguments[0].dictValue.find(arguments[1].stringValue);
        if (found !is null) {
            return *found;
        }
        return arguments.length == 3 ? arguments[2] : Value.nullValue();

    case "getVar":
        if (arguments.length != 1 ||
                arguments[0].kind != ValueKind.stringValue) {
            throw new YshTypeError("getVar() expects one Str argument");
        }
        auto cell = mem.getCell(arguments[0].stringValue);
        return cell is null ? Value.nullValue() : cell.value;

    case "type":
        if (arguments.length != 1) {
            throw new YshTypeError("type() expects one argument");
        }
        return Value.str(kindName(arguments[0]));

    case "int":
        if (arguments.length != 1) {
            throw new YshTypeError("int() expects one argument");
        }
        return Value.integer(convertToInt(arguments[0]));

    case "float":
        if (arguments.length != 1) {
            throw new YshTypeError("float() expects one argument");
        }
        auto floatNumber = convertToNumber(arguments[0]);
        return Value.floating(floatNumber.kind == NumericKind.integer
            ? bigintToDouble(floatNumber.integerValue)
            : floatNumber.floatValue);

    case "str":
        if (arguments.length != 1) {
            throw new YshTypeError("str() expects one argument");
        }
        return Value.str(stringify(arguments[0]));

    case "bool":
        if (arguments.length != 1) {
            throw new YshTypeError("bool() expects one argument");
        }
        return Value.boolean(toBool(arguments[0]));

    case "glob":
        if (arguments.length != 1 ||
                arguments[0].kind != ValueKind.stringValue) {
            throw new YshTypeError("glob() expects one Str pattern");
        }

        auto pattern = arguments[0].stringValue;
        auto directory = dirName(pattern);
        auto leafPattern = baseName(pattern);
        if (directory.length == 0) {
            directory = ".";
        }

        Value[] matches;
        try {
            auto entries = dirEntries(directory, leafPattern,
                SpanMode.shallow).array;
            entries.sort!((a, b) => a.name < b.name);
            foreach (entry; entries) {
                auto matchName = directory == "."
                    ? baseName(entry.name)
                    : entry.name;
                matches ~= Value.str(matchName);
            }
        } catch (Exception error) {
            // Shell-style glob() returns an empty list when the directory or
            // pattern has no matches; filesystem access errors at an existing
            // directory are still surfaced by dirEntries on iteration.
        }
        return Value.list(matches);

    case "list":
        if (arguments.length != 1) {
            throw new YshTypeError("list() expects one argument");
        }
        switch (arguments[0].kind) {
        case ValueKind.list:
            return Value.list(arguments[0].listValue.items.dup);
        case ValueKind.dict:
            Value[] keys;
            foreach (key; arguments[0].dictValue.keys()) {
                keys ~= Value.str(key);
            }
            return Value.list(keys);
        case ValueKind.rangeValue:
            Value[] items;
            for (auto i = arguments[0].rangeLower;
                    i < arguments[0].rangeUpper; ++i) {
                items ~= Value.integer(i);
            }
            return Value.list(items);
        case ValueKind.stringValue:
            Value[] chars;
            foreach (dchar ch; arguments[0].stringValue) {
                chars ~= Value.str(ch.to!string);
            }
            return Value.list(chars);
        default:
            throw new YshTypeError("list() expects List, Dict, Range, or Str");
        }

    case "keys":
        if (arguments.length != 1 ||
                arguments[0].kind != ValueKind.dict) {
            throw new YshTypeError("keys() expects one Dict");
        }
        Value[] keyValues;
        foreach (key; arguments[0].dictValue.keys()) {
            keyValues ~= Value.str(key);
        }
        return Value.list(keyValues);

    case "values":
        if (arguments.length != 1 ||
                arguments[0].kind != ValueKind.dict) {
            throw new YshTypeError("values() expects one Dict");
        }
        return Value.list(arguments[0].dictValue.values());

    case "strcmp":
        if (arguments.length != 2 ||
                arguments[0].kind != ValueKind.stringValue ||
                arguments[1].kind != ValueKind.stringValue) {
            throw new YshTypeError("strcmp() expects two Str arguments");
        }
        return Value.integer(arguments[0].stringValue <
                arguments[1].stringValue ? -1 :
            (arguments[0].stringValue > arguments[1].stringValue ? 1 : 0));

    default:
        assert(false, "unknown builtin function");
    }
}

private long methodInt(Value value, string description) {
    return bigIntToLong(convertToInt(value), description);
}

private string requireString(Value value, string description) {
    if (value.kind != ValueKind.stringValue) {
        throw new YshTypeError(description);
    }
    return value.stringValue;
}

private Value[] splitExact(string source, string separator, long count = -1) {
    if (separator.length == 0) {
        throw new YshTypeError("split separator cannot be empty");
    }
    if (source.length == 0) {
        return [];
    }

    Value[] result;
    size_t start;
    long used;
    while (count < 0 || used < count) {
        auto relative = source[start .. $].indexOf(separator);
        if (relative < 0) {
            break;
        }
        auto cut = start + cast(size_t)relative;
        result ~= Value.str(source[start .. cut]);
        start = cut + separator.length;
        ++used;
    }
    result ~= Value.str(source[start .. $]);
    return result;
}

private long normalizeSearchStart(long start, size_t length) {
    auto n = cast(long)length;
    return start < 0 ? (start + n < 0 ? 0 : start + n) : start;
}

private long normalizeSearchEnd(long end, size_t length) {
    auto n = cast(long)length;
    auto value = end < 0 ? end + n : end;
    if (value < 0) {
        return 0;
    }
    return value > n ? n : value;
}

private bool valueMethodExists(ValueKind kind, string name) {
    switch (kind) {
    case ValueKind.stringValue:
        switch (name) {
        case "startsWith":
        case "endsWith":
        case "trimStart":
        case "trimEnd":
        case "trim":
        case "split":
        case "lines":
        case "find":
        case "findLast":
        case "contains":
        case "upper":
        case "lower":
            return true;
        default:
            return false;
        }
    case ValueKind.list:
        switch (name) {
        case "append":
        case "extend":
        case "pop":
        case "clear":
        case "remove":
        case "insert":
        case "reverse":
        case "indexOf":
        case "lastIndexOf":
        case "join":
            return true;
        default:
            return false;
        }
    case ValueKind.dict:
        switch (name) {
        case "keys":
        case "values":
        case "erase":
        case "clear":
        case "get":
        case "inc":
        case "append":
        case "update":
            return true;
        default:
            return false;
        }
    default:
        return false;
    }
}

private Value callValueMethod(Value receiver, string name,
        Value[] arguments, YshDict namedArguments, Memory mem) {
    auto named = namedArguments is null ? new YshDict() : namedArguments;

    final switch (receiver.kind) {
    case ValueKind.stringValue:
        auto s = receiver.stringValue;

        if (name == "startsWith" || name == "endsWith" ||
                name == "contains") {
            if (arguments.length != 1 || named.length != 0) {
                throw new YshTypeError(name ~ "() expects one Str argument");
            }
            auto pattern = requireString(arguments[0],
                name ~ "() expects a Str argument");
            if (name == "startsWith") {
                return Value.boolean(s.startsWith(pattern));
            }
            if (name == "endsWith") {
                return Value.boolean(s.endsWith(pattern));
            }
            return Value.boolean(s.indexOf(pattern) >= 0);
        }

        if (name == "trimStart" || name == "trimEnd" || name == "trim") {
            if (arguments.length > 1 || named.length != 0) {
                throw new YshTypeError(name ~ "() expects zero or one Str");
            }
            if (arguments.length == 0) {
                if (name == "trimStart") {
                    return Value.str(stripLeft(s));
                }
                if (name == "trimEnd") {
                    return Value.str(stripRight(s));
                }
                return Value.str(strip(s));
            }
            auto pattern = requireString(arguments[0],
                name ~ "() expects a Str pattern");
            auto result = s;
            if ((name == "trimStart" || name == "trim") &&
                    result.startsWith(pattern)) {
                result = result[pattern.length .. $];
            }
            if ((name == "trimEnd" || name == "trim") &&
                    result.endsWith(pattern)) {
                result = result[0 .. $ - pattern.length];
            }
            return Value.str(result);
        }

        if (name == "split") {
            if (arguments.length != 1) {
                throw new YshTypeError("split() expects one Str separator");
            }
            auto separator = requireString(arguments[0],
                "split() expects a Str separator");
            long count = -1;
            auto countValue = named.find("count");
            if (countValue !is null) {
                count = methodInt(*countValue, "split count should be Int");
            }
            if (named.length > (countValue is null ? 0 : 1)) {
                throw new YshTypeError("split() got unknown named argument");
            }
            return Value.list(splitExact(s, separator, count));
        }

        if (name == "lines") {
            if (arguments.length != 0) {
                throw new YshTypeError("lines() takes no positional arguments");
            }
            string eol = "\n";
            auto eolValue = named.find("eol");
            if (eolValue !is null) {
                eol = requireString(*eolValue, "lines eol should be Str");
            }
            if (named.length > (eolValue is null ? 0 : 1)) {
                throw new YshTypeError("lines() got unknown named argument");
            }
            if (eol.length == 0) {
                throw new YshTypeError("lines eol cannot be empty");
            }
            auto parts = splitExact(s, eol);
            if (parts.length != 0 &&
                    parts[$ - 1].kind == ValueKind.stringValue &&
                    parts[$ - 1].stringValue.length == 0) {
                parts = parts[0 .. $ - 1];
            }
            return Value.list(parts);
        }

        if (name == "find" || name == "findLast") {
            if (arguments.length != 1) {
                throw new YshTypeError(name ~ "() expects one Str needle");
            }
            auto needle = requireString(arguments[0],
                name ~ "() expects a Str needle");
            long start = 0;
            long end = cast(long)s.length;
            auto startValue = named.find("start");
            if (startValue !is null) {
                start = methodInt(*startValue, name ~ " start should be Int");
            }
            auto endValue = named.find("end");
            if (endValue !is null) {
                end = methodInt(*endValue, name ~ " end should be Int");
            }
            auto knownNamed = (startValue is null ? 0 : 1) +
                (endValue is null ? 0 : 1);
            if (named.length > knownNamed) {
                throw new YshTypeError(name ~ "() got unknown named argument");
            }

            start = normalizeSearchStart(start, s.length);
            end = normalizeSearchEnd(end, s.length);
            if (start > cast(long)s.length || start > end) {
                return Value.integer(-1);
            }

            auto slice = s[cast(size_t)start .. cast(size_t)end];
            auto relative = name == "find"
                ? slice.indexOf(needle)
                : slice.lastIndexOf(needle);
            return Value.integer(relative < 0 ? -1 :
                start + cast(long)relative);
        }

        if (name == "upper" || name == "lower") {
            if (arguments.length != 0 || named.length != 0) {
                throw new YshTypeError(name ~ "() expects no arguments");
            }
            return Value.str(name == "upper" ? toUpper(s) : toLower(s));
        }

        throw new YshTypeError("unknown Str method " ~ name);

    case ValueKind.list:
        auto list = receiver.listValue;

        if (name == "append") {
            if (arguments.length != 1 || named.length != 0) {
                throw new YshTypeError("append() expects one argument");
            }
            list.items ~= arguments[0];
            return Value.nullValue();
        }
        if (name == "extend") {
            if (arguments.length != 1 ||
                    arguments[0].kind != ValueKind.list ||
                    named.length != 0) {
                throw new YshTypeError("extend() expects one List");
            }
            list.items ~= arguments[0].listValue.items;
            return Value.nullValue();
        }
        if (name == "pop") {
            if (arguments.length != 0 || named.length != 0 ||
                    list.items.length == 0) {
                throw new YshTypeError("pop() expects a non-empty List");
            }
            auto result = list.items[$ - 1];
            list.items = list.items[0 .. $ - 1];
            return result;
        }
        if (name == "clear") {
            if (arguments.length != 0 || named.length != 0) {
                throw new YshTypeError("clear() expects no arguments");
            }
            list.items.length = 0;
            return Value.nullValue();
        }
        if (name == "remove") {
            if (arguments.length != 1 || named.length != 0) {
                throw new YshTypeError("remove() expects one argument");
            }
            foreach (index, item; list.items) {
                if (exactlyEqual(item, arguments[0])) {
                    list.items = list.items[0 .. index] ~
                        list.items[index + 1 .. $];
                    break;
                }
            }
            return Value.nullValue();
        }
        if (name == "insert") {
            if (arguments.length != 2 || named.length != 0) {
                throw new YshTypeError("insert() expects index and value");
            }
            auto index = methodInt(arguments[0], "insert index should be Int");
            auto n = cast(long)list.items.length;
            if (index < 0) {
                index += n;
                if (index < 0) {
                    index = 0;
                }
            }
            if (index > n) {
                index = n;
            }
            auto i = cast(size_t)index;
            list.items = list.items[0 .. i] ~ [arguments[1]] ~
                list.items[i .. $];
            return Value.nullValue();
        }
        if (name == "reverse") {
            if (arguments.length != 0 || named.length != 0) {
                throw new YshTypeError("reverse() expects no arguments");
            }
            reverse(list.items);
            return Value.nullValue();
        }
        if (name == "indexOf" || name == "lastIndexOf") {
            if (arguments.length != 1 || named.length != 0) {
                throw new YshTypeError(name ~ "() expects one argument");
            }
            if (name == "indexOf") {
                foreach (index, item; list.items) {
                    if (exactlyEqual(item, arguments[0])) {
                        return Value.integer(cast(long)index);
                    }
                }
            } else {
                for (auto index = list.items.length; index != 0; --index) {
                    if (exactlyEqual(list.items[index - 1], arguments[0])) {
                        return Value.integer(cast(long)(index - 1));
                    }
                }
            }
            return Value.integer(-1);
        }
        if (name == "join") {
            if (arguments.length > 1 || named.length != 0) {
                throw new YshTypeError("join() expects zero or one Str");
            }
            auto separator = arguments.length == 0
                ? ""
                : requireString(arguments[0], "join separator should be Str");
            string[] pieces;
            foreach (item; list.items) {
                pieces ~= stringify(item);
            }
            return Value.str(pieces.join(separator));
        }

        throw new YshTypeError("unknown List method " ~ name);

    case ValueKind.dict:
        auto dict = receiver.dictValue;

        if (name == "keys" || name == "values") {
            if (arguments.length != 0 || named.length != 0) {
                throw new YshTypeError(name ~ "() expects no arguments");
            }
            if (name == "keys") {
                Value[] keys;
                foreach (key; dict.keys()) {
                    keys ~= Value.str(key);
                }
                return Value.list(keys);
            }
            return Value.list(dict.values());
        }
        if (name == "erase") {
            if (arguments.length != 1 || named.length != 0) {
                throw new YshTypeError("erase() expects one Str key");
            }
            dict.erase(requireString(arguments[0],
                "erase() expects a Str key"));
            return Value.nullValue();
        }
        if (name == "clear") {
            if (arguments.length != 0 || named.length != 0) {
                throw new YshTypeError("clear() expects no arguments");
            }
            dict.clear();
            return Value.nullValue();
        }
        if (name == "get") {
            if (arguments.length < 1 || arguments.length > 2 ||
                    named.length != 0) {
                throw new YshTypeError("get() expects key and optional fallback");
            }
            auto key = requireString(arguments[0], "get key should be Str");
            auto fallback = arguments.length == 2
                ? arguments[1] : Value.nullValue();
            return dict.getOr(key, fallback);
        }
        if (name == "inc") {
            if (arguments.length != 2 || named.length != 0) {
                throw new YshTypeError("inc() expects key and amount");
            }
            auto key = requireString(arguments[0], "inc key should be Str");
            auto old = dict.find(key);
            auto next = old is null ? arguments[1] :
                numericBinary("+", *old, arguments[1]);
            dict.set(key, next);
            return Value.nullValue();
        }
        if (name == "append") {
            if (arguments.length != 2 || named.length != 0) {
                throw new YshTypeError("Dict append() expects key and value");
            }
            auto key = requireString(arguments[0], "append key should be Str");
            auto old = dict.find(key);
            if (old is null) {
                dict.set(key, Value.list([arguments[1]]));
            } else {
                if (old.kind != ValueKind.list) {
                    throw new YshTypeError(
                        "Dict append() requires an existing List value");
                }
                old.listValue.items ~= arguments[1];
            }
            return Value.nullValue();
        }
        if (name == "update") {
            if (arguments.length != 1 ||
                    arguments[0].kind != ValueKind.dict ||
                    named.length != 0) {
                throw new YshTypeError("update() expects one Dict");
            }
            foreach (key, value; arguments[0].dictValue) {
                dict.set(key, value);
            }
            return Value.nullValue();
        }

        throw new YshTypeError("unknown Dict method " ~ name);

    case ValueKind.nullValue:
    case ValueKind.boolean:
    case ValueKind.integer:
    case ValueKind.floating:
    case ValueKind.sliceValue:
    case ValueKind.rangeValue:
    case ValueKind.functionValue:
    case ValueKind.procValue:
        throw new YshTypeError("value has no method " ~ name);
    }
}

private class YshBoundMethod {
    private Value receiver_;
    private string name_;
    private bool mutating_;

    this(Value receiver, string name, bool mutating) {
        receiver_ = receiver;
        name_ = name;
        mutating_ = mutating;
    }

    Value invoke(Value[] arguments, YshDict namedArguments, Memory mem) {
        return callValueMethod(receiver_, name_, arguments,
            namedArguments, mem);
    }
}

private class MethodExpr : Expr {
    private Expr receiver_;
    private string name_;
    private bool mutating_;

    this(Expr receiver, string name, bool mutating) {
        receiver_ = receiver;
        name_ = name;
        mutating_ = mutating;
    }

    override Value eval(Memory mem) {
        auto receiver = receiver_.eval(mem);
        if (valueMethodExists(receiver.kind, name_)) {
            return Value.callable(new YshBoundMethod(
                receiver, name_, mutating_));
        }

        if (builtinFunctionName(name_)) {
            return Value.callable(new YshPipelineFunction(receiver, name_));
        }
        throw new YshTypeError("unknown method or chained function " ~ name_);
    }
}

private class YshPipelineFunction {
    private Value receiver_;
    private string name_;

    this(Value receiver, string name) {
        receiver_ = receiver;
        name_ = name;
    }

    Value invoke(Value[] arguments, YshDict namedArguments, Memory mem) {
        Value[] all = [receiver_];
        all ~= arguments;
        return callBuiltinFunction(name_, all, namedArguments, mem);
    }
}

private class CallExpr : Expr {
    private Expr callee_;
    private PositionalCallArgument[] positional_;
    private NamedCallArgument[] named_;

    this(Expr callee, PositionalCallArgument[] positional,
            NamedCallArgument[] named) {
        callee_ = callee;
        positional_ = positional;
        named_ = named;
    }

    override Value eval(Memory mem) {
        Value[] arguments;
        foreach (argument; positional_) {
            auto value = argument.expression.eval(mem);
            if (!argument.spread) {
                arguments ~= value;
                continue;
            }
            if (value.kind != ValueKind.list) {
                throw new YshTypeError("positional ... spread requires List");
            }
            arguments ~= value.listValue.items;
        }

        YshDict namedArguments;
        if (named_.length != 0) {
            namedArguments = new YshDict();
        }
        foreach (argument; named_) {
            auto value = argument.expression.eval(mem);
            if (!argument.spread) {
                namedArguments.set(argument.name, value);
                continue;
            }
            if (value.kind != ValueKind.dict) {
                throw new YshTypeError("named ... spread requires Dict");
            }
            foreach (key, item; value.dictValue) {
                namedArguments.set(key, item);
            }
        }

        if (auto variable = cast(VariableExpr)callee_) {
            auto cell = mem.getCell(variable.name_);
            if (cell is null && builtinFunctionName(variable.name_)) {
                return callBuiltinFunction(variable.name_, arguments,
                    namedArguments, mem);
            }
        }

        auto callee = callee_.eval(mem);
        if (callee.kind != ValueKind.functionValue) {
            throw new YshTypeError("YSH expression call requires Func");
        }
        auto userFunction = cast(YshFunction)callee.callableValue;
        if (userFunction !is null) {
            return userFunction.invoke(arguments, namedArguments, mem);
        }
        auto boundMethod = cast(YshBoundMethod)callee.callableValue;
        if (boundMethod !is null) {
            return boundMethod.invoke(arguments, namedArguments, mem);
        }
        auto pipelineFunction = cast(YshPipelineFunction)callee.callableValue;
        if (pipelineFunction !is null) {
            return pipelineFunction.invoke(arguments, namedArguments, mem);
        }
        throw new YshTypeError("unknown callable value");
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
        return subscriptGet(object, index);
    }

    if (auto attribute = cast(AttributeExpr)expression) {
        auto object = evalLeftObject(attribute.object_, mem, assignmentScope);
        if (object.kind != ValueKind.dict) {
            throw new YshTypeError("attribute lookup expected Dict");
        }
        auto found = object.dictValue.find(attribute.name_);
        if (found is null) {
            throw new YshError(format(
                "Dict key not found: '%s'", attribute.name_));
        }
        return *found;
    }

    throw new YshError("invalid left side for setvar/setglobal");
}

private class ScalarStringExpr : Expr {
    private Expr child_;

    this(Expr child) {
        child_ = child;
    }

    override Value eval(Memory mem) {
        return Value.str(stringify(child_.eval(mem)));
    }
}

private class ArrayStringExpr : Expr {
    private Expr child_;

    this(Expr child) {
        child_ = child;
    }

    override Value eval(Memory mem) {
        auto value = child_.eval(mem);
        if (value.kind != ValueKind.list) {
            throw new YshTypeError("@[expr] expects List");
        }

        Value[] items;
        foreach (item; value.listValue.items) {
            items ~= Value.str(stringify(item));
        }
        return Value.list(items);
    }
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
        case "~":
            // Infinite-precision two's-complement identity.
            return Value.integer(-convertToInt(value) - 1);
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
        case "&":
        case "|":
        case "^":
        case "<<":
        case ">>":
            return intBinary(op_, left, right);
        case "++":
            return concat(left, right);
        default:
            assert(false, "unknown binary operator");
        }
    }
}

private class IfExpr : Expr {
    private Expr test_;
    private Expr body_;
    private Expr alternative_;

    this(Expr test, Expr body, Expr alternative) {
        test_ = test;
        body_ = body;
        alternative_ = alternative;
    }

    override Value eval(Memory mem) {
        return toBool(test_.eval(mem))
            ? body_.eval(mem)
            : alternative_.eval(mem);
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
                result = right.dictValue.contains(left.stringValue);
                break;
            case CompareOp.notContains:
                if (right.kind != ValueKind.dict) {
                    throw new YshTypeError("RHS of 'not in' should be Dict");
                }
                if (left.kind != ValueKind.stringValue) {
                    throw new YshTypeError("LHS of 'not in' should be Str");
                }
                result = !right.dictValue.contains(left.stringValue);
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
        Expr result = parseTest();
        if (current_.kind != TokenKind.eof) {
            throw new ParseError(format("unexpected '%s' at byte %s", current_.text, current_.offset));
        }
        return result;
    }

    private void advance() {
        current_ = lexer_.next();
    }

    private Expr parseTest() {
        Expr body = parseOr();
        if (current_.kind == TokenKind.ifKeyword) {
            advance();
            auto condition = parseOr();
            require(TokenKind.elseKeyword, "else");
            auto alternative = parseTest();
            return new IfExpr(condition, body, alternative);
        }
        return body;
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
        Expr left = parseRange();
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
            comparators ~= parseRange();
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

    private Expr parseRange() {
        Expr lower = parseBitOr();
        if (current_.kind == TokenKind.dotDotLess ||
                current_.kind == TokenKind.dotDotEqual) {
            bool closed = current_.kind == TokenKind.dotDotEqual;
            advance();
            auto upper = parseBitOr();
            return new RangeExpr(lower, upper, closed);
        }
        return lower;
    }

    private Expr parseBitOr() {
        Expr left = parseBitXor();
        while (current_.kind == TokenKind.pipe) {
            advance();
            left = new BinaryExpr("|", left, parseBitXor());
        }
        return left;
    }

    private Expr parseBitXor() {
        Expr left = parseBitAnd();
        while (current_.kind == TokenKind.caret) {
            advance();
            left = new BinaryExpr("^", left, parseBitAnd());
        }
        return left;
    }

    private Expr parseBitAnd() {
        Expr left = parseShift();
        while (current_.kind == TokenKind.amp) {
            advance();
            left = new BinaryExpr("&", left, parseShift());
        }
        return left;
    }

    private Expr parseShift() {
        Expr left = parseAdditive();
        while (current_.kind == TokenKind.shiftLeft ||
                current_.kind == TokenKind.shiftRight) {
            auto op = current_.text;
            advance();
            left = new BinaryExpr(op, left, parseAdditive());
        }
        return left;
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
        if (current_.kind == TokenKind.plus ||
                current_.kind == TokenKind.minus ||
                current_.kind == TokenKind.tilde) {
            auto op = current_.text;
            advance();
            return new UnaryExpr(op, parseFactor());
        }
        return parsePower();
    }

    // Mirrors grammar.pgen2: power -> atom trailer* ['**' factor].
    private Expr parsePower() {
        Expr left = parseAtom();

        while (current_.kind == TokenKind.leftBracket ||
                current_.kind == TokenKind.leftParen ||
                current_.kind == TokenKind.dot ||
                current_.kind == TokenKind.fatArrow ||
                current_.kind == TokenKind.thinArrow) {
            if (current_.kind == TokenKind.leftBracket) {
                advance();

                Expr index;
                if (current_.kind == TokenKind.colon) {
                    advance();
                    Expr upper;
                    if (current_.kind != TokenKind.rightBracket) {
                        upper = parseOr();
                    }
                    index = new SliceExpr(null, upper);
                } else {
                    auto first = parseOr();
                    if (current_.kind == TokenKind.colon) {
                        advance();
                        Expr upper;
                        if (current_.kind != TokenKind.rightBracket) {
                            upper = parseOr();
                        }
                        index = new SliceExpr(first, upper);
                    } else {
                        index = first;
                    }
                }

                require(TokenKind.rightBracket, "]");
                left = new SubscriptExpr(left, index);
            } else if (current_.kind == TokenKind.leftParen) {
                advance();
                PositionalCallArgument[] positionalArguments;
                NamedCallArgument[] namedArguments;
                bool namedGroup;

                while (current_.kind != TokenKind.rightParen) {
                    if (current_.kind == TokenKind.semicolon) {
                        if (namedGroup) {
                            throw new ParseError(
                                "function call has more than one named-argument separator");
                        }
                        namedGroup = true;
                        advance();
                        continue;
                    }

                    if (current_.kind == TokenKind.ellipsis) {
                        advance();
                        auto expression = parseTest();
                        if (namedGroup) {
                            namedArguments ~= NamedCallArgument(
                                "", expression, true);
                        } else {
                            positionalArguments ~= PositionalCallArgument(
                                expression, true);
                        }
                    } else if (current_.kind == TokenKind.name &&
                            lexer_.peek().kind == TokenKind.equal) {
                        auto name = current_.text;
                        advance();
                        require(TokenKind.equal, "=");
                        namedArguments ~= NamedCallArgument(
                            name, parseTest(), false);
                    } else {
                        if (namedGroup) {
                            throw new ParseError(format(
                                "expected named argument at byte %s",
                                current_.offset));
                        }
                        positionalArguments ~= PositionalCallArgument(
                            parseTest(), false);
                    }

                    if (current_.kind == TokenKind.comma) {
                        advance();
                        continue;
                    }
                    if (current_.kind == TokenKind.semicolon) {
                        continue;
                    }
                    break;
                }

                require(TokenKind.rightParen, ")");
                left = new CallExpr(left, positionalArguments, namedArguments);
            } else {
                auto accessKind = current_.kind;
                advance();
                if (current_.kind != TokenKind.name) {
                    throw new ParseError(format(
                        "expected attribute or method name at byte %s",
                        current_.offset));
                }
                auto name = current_.text;
                advance();
                if (accessKind == TokenKind.dot) {
                    left = new AttributeExpr(left, name);
                } else {
                    left = new MethodExpr(left, name,
                        accessKind == TokenKind.thinArrow);
                }
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
        case TokenKind.doubleQuoted:
            advance();
            return new DoubleQuotedExpr(token.text);
        case TokenKind.stringValue:
        case TokenKind.charValue:
            advance();
            return new LiteralExpr(Value.str(token.text));
        case TokenKind.name:
            advance();
            return new VariableExpr(token.text);
        case TokenKind.dollar:
            advance();
            require(TokenKind.leftBracket, "[");
            auto scalarChild = parseTest();
            require(TokenKind.rightBracket, "]");
            return new ScalarStringExpr(scalarChild);
        case TokenKind.at:
            advance();
            require(TokenKind.leftBracket, "[");
            auto arrayChild = parseTest();
            require(TokenKind.rightBracket, "]");
            return new ArrayStringExpr(arrayChild);
        case TokenKind.leftParen:
            advance();
            if (current_.kind == TokenKind.rightParen) {
                advance();
                return new ListExpr([]);
            }

            Expr first = parseTest();
            if (current_.kind != TokenKind.comma) {
                require(TokenKind.rightParen, ")");
                return first;
            }

            Expr[] items = [first];
            while (current_.kind == TokenKind.comma) {
                advance();
                if (current_.kind == TokenKind.rightParen) {
                    break;
                }
                items ~= parseTest();
            }
            require(TokenKind.rightParen, ")");
            return new ListExpr(items);
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
                items ~= parseTest();
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
        Expr[] keys;
        Expr[] values;

        if (current_.kind != TokenKind.rightBrace) {
            while (true) {
                Expr key;
                Expr value;

                if (current_.kind == TokenKind.name) {
                    auto name = current_.text;
                    key = new LiteralExpr(Value.str(name));
                    advance();
                    if (current_.kind == TokenKind.colon) {
                        advance();
                        value = parseTest();
                    } else {
                        value = new VariableExpr(name);
                    }
                } else if (current_.kind == TokenKind.stringValue ||
                        current_.kind == TokenKind.charValue) {
                    key = new LiteralExpr(Value.str(current_.text));
                    advance();
                    require(TokenKind.colon, ":");
                    value = parseTest();
                } else if (current_.kind == TokenKind.leftBracket) {
                    advance();
                    key = parseTest();
                    require(TokenKind.rightBracket, "]");
                    require(TokenKind.colon, ":");
                    value = parseTest();
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
            object_.listValue.items[cast(size_t)i] = value;
            return;
        case ValueKind.dict:
            object_.dictValue.set(dictKey(index_), value);
            return;
        case ValueKind.nullValue:
        case ValueKind.boolean:
        case ValueKind.integer:
        case ValueKind.floating:
        case ValueKind.stringValue:
        case ValueKind.sliceValue:
        case ValueKind.rangeValue:
        case ValueKind.functionValue:
        case ValueKind.procValue:
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
    assert(repr(evaluate("10 if true else 20")) == "10");
    assert(repr(evaluate("10 if false else 20")) == "20");
    assert(repr(evaluate("1 if false else 2 if false else 3")) == "3");
    assert(repr(evaluate("(1, 2, 3)")) == "[1, 2, 3]");
    assert(repr(evaluate("()")) == "[]");
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
    mem.declareLocal("key", Value.str("computed"));
    assert(repr(evaluate("{[key]: 7}['computed']", mem)) == "7");
    assert(repr(evaluate("[10, 20, 30][1]", mem)) == "20");
    assert(repr(evaluate("'answer' in {answer: 42}", mem)) == "true");
    assert(repr(evaluate("'missing' not in {answer: 42}", mem)) == "true");

    assert(repr(evaluate("1 | 2 ^ 3 & 1")) == "3");
    assert(repr(evaluate("1 << 4")) == "16");
    assert(repr(evaluate("16 >> 2")) == "4");
    assert(repr(evaluate("~0")) == "-1");
    assert(repr(evaluate("1 ..< 4")) == "1..<4");
    assert(repr(evaluate("1 ..= 3")) == "1..<4");
    assert(repr(evaluate("$[1 + 2]")) == "\"3\"");
    assert(repr(evaluate("@[[1, 2, 3]]")) == "[\"1\", \"2\", \"3\"]");

    assert(repr(evaluate("[0, 1, 2, 3][1:3]")) == "[1, 2]");
    assert(repr(evaluate("[0, 1, 2, 3][:2]")) == "[0, 1]");
    assert(repr(evaluate("[0, 1, 2, 3][2:]")) == "[2, 3]");
    assert(repr(evaluate("'abcd'[1:3]")) == "\"bc\"");
    assert(repr(evaluate("'abcd'[-1]")) == "\"d\"");

    mem.declareLocal("items", evaluate("[1, 2, 3]", mem));
    assignPlace("items[1]", Value.integer(42), mem);
    assert(repr(mem.get("items")) == "[1, 42, 3]");

    mem.declareLocal("record", evaluate("{old: 1}", mem));
    assignPlace("record.new", Value.integer(2), mem);
    assert(repr(evaluate("record.new", mem)) == "2");

    assignPlace("x", Value.integer(99), mem);
    assert(repr(evaluate("x", mem)) == "99");
}
