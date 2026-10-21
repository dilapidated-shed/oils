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
import yshd.state : Memory, ReturnMode, Frame;
import yshd.options : ShellOptions;
import yshd.io_ysh : encodeDataValue, WriteEncoding, DataEncodeError, dataOptions;
import yshd.value : Value, ValueKind, YshDict, YshObject, YshError, YshTypeError, StructuredError, FatalRuntimeError,
    exactlyEqual, kindName, stringify, toBool;

class ParseError : YshError {
    this(string message) {
        super(message, 2);
    }
}

private enum CompareOp {
    less,
    greater,
    lessEqual,
    greaterEqual,
    exactEqual,
    notExactEqual,
    approximateEqual,
    contains,
    notContains,
    regexMatch,
    notRegexMatch,
    globMatch,
    notGlobMatch,
    identical,
    notIdentical,
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
            return Numeric(NumericKind.floating, BigInt(0), parseFloating(cleaned));
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
    case ValueKind.placeValue:
    case ValueKind.eggexValue:
    case ValueKind.matchValue:
    case ValueKind.expressionValue:
    case ValueKind.commandValue:
    case ValueKind.objectValue:
    case ValueKind.builtinFunctionValue:
    case ValueKind.boundFunctionValue:
    case ValueKind.bashArrayValue:
    case ValueKind.bashAssocValue:
        throw new YshTypeError(format("expected Int, Float, or numeric Str, got %s", value.kind));
    }
}

private double parseFloating(string text) {
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;
    // YSH permits overflow to infinity and underflow to signed zero.
    return strtod(text.toStringz(), null);
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
    case ValueKind.placeValue:
    case ValueKind.eggexValue:
    case ValueKind.matchValue:
    case ValueKind.expressionValue:
    case ValueKind.commandValue:
    case ValueKind.objectValue:
    case ValueKind.builtinFunctionValue:
    case ValueKind.boundFunctionValue:
    case ValueKind.bashArrayValue:
    case ValueKind.bashAssocValue:
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

/// Values retain the defining lexical and module frames, while streams,
/// special arguments, status and options belong to the evaluating shell.
class YshExpression {
    private Expr expression;
    private Frame captured;
    private Frame moduleFrame;
    this(Expr expression, Memory mem) {
        this.expression = expression;
        captured = mem.currentFrame;
        moduleFrame = mem.globalFrame;
    }
    Value eval(Memory mem) {
        auto previousGlobal = mem.globalFrame;
        mem.globalFrame = moduleFrame;
        mem.pushEnclosed(captured);
        scope (exit) { mem.popFrame(); mem.globalFrame = previousGlobal; }
        auto optionNumbers = mem.options.pushExpression();
        scope (exit) mem.options.pop(optionNumbers);
        return expression.eval(mem);
    }
}

private class ExpressionClosureExpr : Expr {
    Expr expression;
    this(Expr expression) { this.expression = expression; }
    override Value eval(Memory mem) {
        return Value.closure(ValueKind.expressionValue, new YshExpression(expression, mem));
    }
}

private class CommandClosureExpr : Expr {
    string command;
    this(string command) { this.command = command; }
    override Value eval(Memory mem) {
        import yshd.program : YshCommand;
        return Value.closure(ValueKind.commandValue, new YshCommand(command, mem));
    }
}

private class LiteralExpr : Expr {
    private Value value_;

    this(Value value) {
        value_ = value;
    }

    override Value eval(Memory mem) {
        return value_.literalCopy();
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

private class CommandSubstitutionExpr : Expr {
    private string command_;
    this(string command) { command_ = command; }
    override Value eval(Memory mem) {
        import yshd.program : evaluateCommandSubstitution;
        return Value.str(evaluateCommandSubstitution(command_, mem));
    }
}

private class ShellArrayExpr : Expr {
    private string words_;
    this(string words) { words_ = words; }
    override Value eval(Memory mem) {
        import yshd.program : evaluateShellWords;
        Value[] values;
        foreach (word; evaluateShellWords(words_, mem)) values ~= Value.str(word);
        return Value.list(values);
    }
}

private class VariableExpr : Expr {
    private string name_;

    this(string name) {
        name_ = name;
    }

    override Value eval(Memory mem) {
        if (mem.getCell(name_) is null && builtinFunctionName(name_))
            return Value.builtin(new YshNativeFunction(name_));
        return mem.get(name_);
    }

    Value evalLeft(Memory mem, AssignmentScope assignmentScope) {
        return assignmentScope == AssignmentScope.global
            ? mem.getGlobal(name_)
            : mem.getLocal(name_);
    }
}

private class PlaceExpr : Expr {
    string name;
    this(string name) { this.name = name; }
    override Value eval(Memory mem) {
        import yshd.state : FramePlace;
        return Value.place(new FramePlace(mem.currentFrame, name));
    }
}

private class EggexExpr : Expr {
    import yshd.eggex : Eggex;
    Eggex pattern;
    this(Eggex pattern) { this.pattern = pattern; }
    override Value eval(Memory mem) { return Value.eggex(pattern.bind(mem)); }
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
    case ValueKind.placeValue:
    case ValueKind.eggexValue:
    case ValueKind.matchValue:
    case ValueKind.expressionValue:
    case ValueKind.commandValue:
    case ValueKind.objectValue:
    case ValueKind.builtinFunctionValue:
    case ValueKind.boundFunctionValue:
    case ValueKind.bashArrayValue:
    case ValueKind.bashAssocValue:
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
        case ValueKind.placeValue:
        case ValueKind.eggexValue:
        case ValueKind.matchValue:
        case ValueKind.expressionValue:
        case ValueKind.commandValue:
        case ValueKind.objectValue:
        case ValueKind.builtinFunctionValue:
        case ValueKind.boundFunctionValue:
        case ValueKind.bashArrayValue:
        case ValueKind.bashAssocValue:
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
        if (object.kind == ValueKind.objectValue) return objectAttribute(object, name_, false);
        if (object.kind == ValueKind.dict) {
            auto found = object.dictValue.find(name_);
            if (found !is null) {
                return *found;
            }
        }
        if (valueMethodExists(object.kind, name_)) {
            return Value.bound(new YshBoundMethod(object, name_, false));
        }
        if (object.kind == ValueKind.dict) {
            throw new YshError(format("Dict key not found: '%s'", name_));
        }
        throw new YshTypeError("value has no attribute '" ~ name_ ~ "'");
    }

    void assign(Memory mem, Value value) {
        auto object = object_.eval(mem);
        if (object.kind == ValueKind.objectValue) {
            object.objectValue.properties.set(name_, value);
            return;
        }
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

struct EvaluatedArguments {
    Value[] positional;
    YshDict named;
    Value block;
    bool hasBlock;
}

/// Function calls and command typed arguments share one grammar and one
/// left-to-right evaluator. Parsing never evaluates an argument or spread.
class ParsedArguments {
    private PositionalCallArgument[] positional_;
    private NamedCallArgument[] named_;
    private Expr block_;

    Expr singleExpression() {
        if (positional_.length != 1 || positional_[0].spread ||
                named_.length || block_ !is null)
            throw new ParseError("typed return expects exactly one positional argument");
        return positional_[0].expression;
    }

    EvaluatedArguments eval(Memory mem) {
        auto optionNumbers = mem.options.pushExpression();
        scope (exit) mem.options.pop(optionNumbers);
        EvaluatedArguments result;
        result.named = new YshDict();
        foreach (argument; positional_) {
            auto value = argument.expression.eval(mem);
            if (!argument.spread) result.positional ~= value;
            else {
                if (value.kind != ValueKind.list)
                    throw new YshTypeError("positional ... spread requires List");
                result.positional ~= value.listValue.items;
            }
        }
        foreach (argument; named_) {
            auto value = argument.expression.eval(mem);
            if (!argument.spread) result.named.set(argument.name, value);
            else {
                if (value.kind != ValueKind.dict)
                    throw new YshTypeError("named ... spread requires Dict");
                foreach (key, item; value.dictValue) result.named.set(key, item);
            }
        }
        if (block_ !is null) {
            result.hasBlock = true;
            result.block = block_.eval(mem);
        }
        return result;
    }
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
    case "join":
    case "floatsEqual":
    case "strcmp":
    case "_group":
    case "_start":
    case "_end":
    case "toJson":
    case "toJson8":
    case "fromJson":
    case "fromJson8":
    case "Object":
    case "prototype":
    case "propView":
    case "dict":
    case "first":
    case "rest":
        return true;
    default:
        return false;
    }
}

private Value callBuiltinFunction(string name, Value[] arguments,
        YshDict namedArguments, Memory mem) {
    if (namedArguments !is null && namedArguments.length != 0 &&
            name != "toJson" && name != "toJson8") {
        throw new YshTypeError(format("%s() does not accept named arguments yet", name));
    }

    if (name == "Object") {
        if (arguments.length != 2 || arguments[1].kind != ValueKind.dict ||
                (arguments[0].kind != ValueKind.nullValue && arguments[0].kind != ValueKind.objectValue))
            throw new YshTypeError("Object() expects Obj or Null prototype and Dict properties");
        return Value.object(new YshObject(arguments[0].kind == ValueKind.nullValue ? null
            : arguments[0].objectValue, arguments[1].dictValue));
    }
    if (name == "prototype" || name == "propView" || name == "first" || name == "rest") {
        if (arguments.length != 1 || arguments[0].kind != ValueKind.objectValue)
            throw new YshTypeError(name ~ "() expects Obj");
        auto object = arguments[0].objectValue;
        if (name == "propView" || name == "first") return Value.dictRef(object.properties);
        return object.prototype is null ? Value.nullValue() : Value.object(object.prototype);
    }
    if (name == "dict") {
        if (arguments.length != 1) throw new YshTypeError("dict() expects Dict or Obj");
        if (arguments[0].kind == ValueKind.dict) return Value.dictRef(arguments[0].dictValue.shallowCopy());
        if (arguments[0].kind == ValueKind.objectValue) return Value.dictRef(arguments[0].objectValue.properties.shallowCopy());
        throw new YshTypeError("dict() expects Dict or Obj");
    }

    switch (name) {
    case "floatsEqual":
        if (arguments.length != 2 || arguments[0].kind != ValueKind.floating || arguments[1].kind != ValueKind.floating)
            throw new YshTypeError("floatsEqual() expects two Float arguments");
        return Value.boolean(arguments[0].floatValue == arguments[1].floatValue);
    case "join":
        if (arguments.length < 1 || arguments.length > 2 || arguments[0].kind != ValueKind.list)
            throw new YshTypeError("join() expects List and optional Str delimiter");
        auto delimiter = arguments.length == 2 ? requireString(arguments[1], "join delimiter should be Str") : "";
        string[] parts;
        foreach (item; arguments[0].listValue.items) parts ~= stringify(item);
        return Value.str(parts.join(delimiter));
    case "fromJson":
    case "fromJson8":
        import yshd.data_decode : decodeDataValue, DataDecodeError;
        if (arguments.length != 1) throw new YshTypeError(name ~ "() expects one Str argument");
        auto source = requireString(arguments[0], name ~ "() expects a Str");
        try { return decodeDataValue(source, name == "fromJson8"); }
        catch (DataDecodeError error) {
            auto properties = new YshDict();
            properties.set("start_pos", Value.integer(cast(long)error.startPosition));
            properties.set("end_pos", Value.integer(cast(long)error.endPosition));
            throw new StructuredError(4, error.msg, properties);
        }
    case "toJson":
    case "toJson8":
        if (arguments.length != 1) throw new YshTypeError(name ~ "() expects one argument");
        auto options = dataOptions(namedArguments, 0);
        try {
            return Value.str(encodeDataValue(arguments[0],
                name == "toJson" ? WriteEncoding.json : WriteEncoding.j8,
                options.space, options.typeErrors));
        } catch (DataEncodeError error) {
            throw new StructuredError(4, error.msg, new YshDict());
        }
    case "_group":
    case "_start":
    case "_end":
        if (arguments.length != 1) throw new YshTypeError(name ~ "() expects one argument");
        auto match = mem.regexMatch;
        if (match is null) throw new YshError("No regex capture groups");
        return match.capture(arguments[0], name[1 .. $]);
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

private string evaluateReplacement(Value replacement, Memory mem, string dollarZero,
        string[] positional = null, YshDict variables = null, bool changePositional = false) {
    if (replacement.kind == ValueKind.stringValue) return replacement.stringValue;
    auto closure = cast(YshExpression)replacement.callableValue;
    auto previousZero = mem.argumentZero;
    auto previousArguments = mem.shellArguments;
    mem.argumentZero = dollarZero;
    if (changePositional) mem.shellArguments = positional;
    auto frame = mem.currentFrame;
    import yshd.state : Cell;
    Cell[string] previousCells;
    if (variables !is null) foreach (name, value; variables) {
        auto old = name in frame.cells;
        previousCells[name] = old is null ? null : *old;
        frame.cells[name] = new Cell(value);
    }
    scope (exit) {
        mem.argumentZero = previousZero;
        mem.shellArguments = previousArguments;
        foreach (name, cell; previousCells) {
            if (cell is null) frame.cells.remove(name);
            else frame.cells[name] = cell;
        }
    }
    auto value = closure.eval(mem);
    if (value.kind != ValueKind.stringValue) throw new YshTypeError("Expected expr to eval to a Str");
    return value.stringValue;
}

private Value replaceString(string source, Value[] arguments, YshDict named, Memory mem) {
    if (arguments.length != 2 || named.length > (named.contains("count") ? 1 : 0))
        throw new YshTypeError("replace() expects pattern, substitution, and optional count");
    auto pattern = arguments[0];
    auto replacement = arguments[1];
    if (pattern.kind != ValueKind.stringValue && pattern.kind != ValueKind.eggexValue)
        throw new YshTypeError("Expected pattern to be Eggex or Str");
    if (replacement.kind != ValueKind.stringValue && replacement.kind != ValueKind.expressionValue)
        throw new YshTypeError("Expected substitution to be Str or Expr");
    long count = -1;
    if (auto supplied = named.find("count")) {
        if (supplied.kind != ValueKind.integer) throw new YshTypeError("count should be Int");
        count = bigIntToLong(supplied.integerValue, "count should fit Int");
    }
    if (!count) return Value.str(source);
    string result;
    size_t position;
    long replaced;
    if (pattern.kind == ValueKind.stringValue) {
        auto old = pattern.stringValue;
        // The reference evaluates a Str-pattern template once, even when
        // there are no occurrences. Eggex templates run for each match.
        auto substitution = evaluateReplacement(replacement, mem, old);
        while (count < 0 || replaced < count) {
            ptrdiff_t found = -1;
            foreach (index; position .. source.length + 1) {
                if (old.length <= source.length - index && source[index .. index + old.length] == old) {
                    found = index;
                    break;
                }
            }
            if (found < 0) break;
            result ~= source[position .. found] ~ substitution;
            position = found + old.length;
            ++replaced;
            if (!old.length) {
                if (position == source.length) break;
                result ~= source[position++];
            }
        }
    } else {
        if (source.indexOf('\0') >= 0)
            throw new StructuredError(3, "cannot replace by eggex on a string with NUL bytes", new YshDict());
        while (position < source.length && (count < 0 || replaced < count)) {
            auto match = pattern.regexValue.search(source, position, false, false);
            if (match is null) break;
            string[] positional;
            string dollarZero;
            auto variables = new YshDict();
            foreach (index, start; match.starts) {
                auto value = Value.str(start < 0 ? "" : source[start .. match.ends[index]]);
                if (index && index <= match.conversions.length && match.conversions[index - 1] !is null)
                    value = match.conversions[index - 1](value);
                auto text = stringify(value);
                if (!index) dollarZero = text;
                else {
                    positional ~= text;
                    if (index <= match.names.length && match.names[index - 1].length)
                        variables.set(match.names[index - 1], value);
                }
            }
            auto substitution = evaluateReplacement(replacement, mem, dollarZero, positional, variables, true);
            auto start = match.starts[0];
            auto end = match.ends[0];
            if (position == end)
                throw new StructuredError(3, "eggex should never match the empty string", new YshDict());
            result ~= source[position .. start] ~ substitution;
            position = end;
            ++replaced;
        }
    }
    return Value.str(result ~ source[position .. $]);
}

private bool valueMethodExists(ValueKind kind, string name) {
    switch (kind) {
    case ValueKind.matchValue:
        return name == "group" || name == "start" || name == "end";
    case ValueKind.placeValue:
        return name == "setValue";
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
        case "replace":
        case "upper":
        case "lower":
        case "search":
        case "leftMatch":
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
    case ValueKind.matchValue:
        if (arguments.length != 1 || named.length) throw new YshTypeError("Match method expects one argument");
        return receiver.matchValue.capture(arguments[0], name);
    case ValueKind.placeValue:
        if (name != "setValue" || arguments.length != 1 || named.length)
            throw new YshTypeError("Place.setValue() expects one argument");
        receiver.placeValue.assign(arguments[0]);
        return Value.nullValue();
    case ValueKind.stringValue:
        auto s = receiver.stringValue;

        if (name == "replace") return replaceString(s, arguments, named, mem);

        if (name == "search" || name == "leftMatch") {
            import yshd.eggex : searchEre;
            if (arguments.length != 1 || named.length > (named.contains("pos") ? 1 : 0))
                throw new YshTypeError(name ~ "() expects one pattern and optional pos");
            long position;
            if (auto pos = named.find("pos")) {
                if (pos.kind != ValueKind.integer) throw new YshTypeError("pos should be Int");
                position = bigIntToLong(pos.integerValue, "pos should fit Int");
            }
            auto pattern = arguments[0];
            import yshd.value : RegexMatch;
            RegexMatch match;
            if (pattern.kind == ValueKind.eggexValue) match = pattern.regexValue.search(s, position, name == "leftMatch");
            else if (pattern.kind == ValueKind.stringValue) match = searchEre(pattern.stringValue, 0, s, position, name == "leftMatch");
            else throw new YshTypeError("search pattern should be Eggex or Str");
            return match is null ? Value.nullValue() : Value.match(match);
        }

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
            // YSH Str search uses byte offsets, including slice bounds that
            // split UTF-8. D's Unicode reverse traversal is inappropriate.
            ptrdiff_t relative = -1;
            if (needle.length <= slice.length) {
                auto limit = slice.length - needle.length;
                for (size_t i = 0; i <= limit; ++i) {
                    auto offset = name == "find" ? i : limit - i;
                    if (slice[offset .. offset + needle.length] == needle) {
                        relative = cast(ptrdiff_t)offset;
                        break;
                    }
                }
            }
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
    case ValueKind.eggexValue:
    case ValueKind.expressionValue:
    case ValueKind.commandValue:
    case ValueKind.objectValue:
    case ValueKind.builtinFunctionValue:
    case ValueKind.boundFunctionValue:
    case ValueKind.bashArrayValue:
    case ValueKind.bashAssocValue:
        throw new YshTypeError("value has no method " ~ name);
    }
}

private Value objectAttribute(Value receiver, string name, bool mutating) {
    auto object = receiver.objectValue;
    if (!mutating) if (auto own = object.properties.find(name)) return *own;
    auto prototype = object.prototype;
    auto inherited = prototype is null ? null : prototype.find(mutating ? "M/" ~ name : name);
    if (inherited is null) throw new YshError("Attribute not found on Obj prototype: " ~ name);
    if (inherited.kind == ValueKind.functionValue || inherited.kind == ValueKind.builtinFunctionValue)
        return Value.bound(new YshObjectMethod(receiver, *inherited));
    return *inherited;
}

private class YshObjectMethod {
    Value receiver;
    Value target;
    this(Value receiver, Value target) { this.receiver = receiver; this.target = target; }
    Value invoke(Value[] arguments, YshDict named, Memory mem) {
        return invokeFunction(target, [receiver] ~ arguments, named, mem);
    }
}

private class YshNativeFunction {
    string name;
    this(string name) { this.name = name; }
    Value invoke(Value[] arguments, YshDict named, Memory mem) {
        if (name == "Obj.new") {
            if (arguments.length < 1 || arguments.length > 2 || (named !is null && named.length))
                throw new YshTypeError("Obj.new() expects properties and optional prototype");
            return callBuiltinFunction("Object", [arguments.length == 2 ? arguments[1] : Value.nullValue(), arguments[0]], null, mem);
        }
        if (name == "io.eval" || name == "io.evalExpr") {
            if (arguments.length != 2 || arguments[0].kind != ValueKind.objectValue || (named !is null && named.length))
                throw new YshTypeError(name ~ "() expects one captured value");
            if (name == "io.eval") {
                if (arguments[1].kind != ValueKind.commandValue) throw new YshTypeError("io.eval() expects Command");
                import yshd.program : YshCommand;
                (cast(YshCommand)arguments[1].callableValue).eval(mem);
                return Value.nullValue();
            }
            if (arguments[1].kind != ValueKind.expressionValue) throw new YshTypeError("io.evalExpr() expects Expr");
            return (cast(YshExpression)arguments[1].callableValue).eval(mem);
        }
        return callBuiltinFunction(name, arguments, named, mem);
    }
}

Value builtinFunctionValue(string name) {
    return builtinFunctionName(name) ? Value.builtin(new YshNativeFunction(name)) : Value.nullValue();
}

/// Namespace objects use the same own-property/prototype rules as user Obj
/// values. Keep them in builtin lookup, outside the user's lexical frames.
Value[string] builtinNamespaces() {
    Value[string] result;
    auto objectFunctions = new YshDict();
    objectFunctions.set("new", Value.builtin(new YshNativeFunction("Obj.new")));
    result["Obj"] = Value.object(new YshObject(null, objectFunctions));
    auto ioMethods = new YshDict();
    ioMethods.set("M/eval", Value.builtin(new YshNativeFunction("io.eval")));
    ioMethods.set("M/evalExpr", Value.builtin(new YshNativeFunction("io.evalExpr")));
    result["io"] = Value.object(new YshObject(new YshObject(null, ioMethods), new YshDict()));
    return result;
}

private Value invokeFunction(Value callee, Value[] arguments, YshDict named, Memory mem) {
    if (callee.kind != ValueKind.functionValue && callee.kind != ValueKind.builtinFunctionValue && callee.kind != ValueKind.boundFunctionValue)
        throw new YshTypeError("YSH expression call requires Func");
    if (auto userFunction = cast(YshFunction)callee.callableValue) return userFunction.invoke(arguments, named, mem);
    if (auto builtin = cast(YshNativeFunction)callee.callableValue) return builtin.invoke(arguments, named, mem);
    if (auto objectMethod = cast(YshObjectMethod)callee.callableValue) return objectMethod.invoke(arguments, named, mem);
    if (auto bound = cast(YshBoundMethod)callee.callableValue) return bound.invoke(arguments, named, mem);
    if (auto pipeline = cast(YshPipelineFunction)callee.callableValue) return pipeline.invoke(arguments, named, mem);
    throw new YshTypeError("Unknown callable value");
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
        if (receiver.kind == ValueKind.objectValue) return objectAttribute(receiver, name_, mutating_);
        if (valueMethodExists(receiver.kind, name_)) {
            return Value.bound(new YshBoundMethod(
                receiver, name_, mutating_));
        }

        if (builtinFunctionName(name_)) {
            return Value.bound(new YshPipelineFunction(receiver, name_));
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

/// Resolve a capture converter when its Eggex is evaluated, preserving the
/// callable even if the name is rebound before _group() retrieves the match.
Value delegate(Value) resolveCaptureConversion(string name, Memory mem) {
    if (mem.getCell(name) is null && builtinFunctionName(name)) {
        return (Value argument) { return callBuiltinFunction(name, [argument], null, mem); };
    }
    auto value = mem.get(name);
    if (value.kind != ValueKind.functionValue && value.kind != ValueKind.builtinFunctionValue)
        throw new YshTypeError("Capture converter requires Func");
    return (Value argument) { return invokeFunction(value, [argument], null, mem); };
}

private class CallExpr : Expr {
    private Expr callee_;
    private ParsedArguments arguments_;

    this(Expr callee, ParsedArguments arguments) {
        callee_ = callee;
        arguments_ = arguments;
    }

    override Value eval(Memory mem) {
        string builtinName;
        if (auto variable = cast(VariableExpr)callee_) {
            auto cell = mem.getCell(variable.name_);
            if (cell is null && builtinFunctionName(variable.name_)) builtinName = variable.name_;
        }
        // Resolve the callee before evaluating arguments, which may rebind it.
        if (builtinName.length) {
            auto args = arguments_.eval(mem);
            return callBuiltinFunction(builtinName, args.positional, args.named, mem);
        }
        auto callee = callee_.eval(mem);
        auto args = arguments_.eval(mem);
        return invokeFunction(callee, args.positional, args.named, mem);
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
        if (object.kind == ValueKind.objectValue) return objectAttribute(object, attribute.name_, false);
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
            case CompareOp.approximateEqual:
                if (left.kind != ValueKind.stringValue)
                    throw new FatalRuntimeError("~== expects a string on the left");
                auto text = strip(left.stringValue);
                switch (right.kind) {
                case ValueKind.stringValue: result = text == right.stringValue; break;
                case ValueKind.boolean:
                    auto lower = toLower(text);
                    result = (lower == "true" || lower == "false") &&
                        (lower == "true") == right.booleanValue;
                    break;
                case ValueKind.integer:
                    result = looksLikeYshInt(text) && BigInt(text.replace("_", "")) == right.integerValue;
                    break;
                default: throw new FatalRuntimeError("~== expects Str, Int, or Bool on the right");
                }
                break;
            case CompareOp.regexMatch:
            case CompareOp.notRegexMatch:
                import yshd.eggex : searchEre;
                import yshd.value : RegexMatch;
                if (left.kind != ValueKind.stringValue) throw new YshTypeError("LHS of regex match must be Str");
                RegexMatch match;
                if (right.kind == ValueKind.eggexValue) match = right.regexValue.search(left.stringValue);
                else if (right.kind == ValueKind.stringValue) match = searchEre(right.stringValue, 0, left.stringValue);
                else throw new YshTypeError("RHS of regex match must be Eggex or Str");
                if (op == CompareOp.regexMatch) mem.regexMatch = match;
                result = (match !is null) == (op == CompareOp.regexMatch);
                break;
            case CompareOp.globMatch:
            case CompareOp.notGlobMatch:
                import yshd.libc_patterns : fnmatch;
                import std.string : toStringz;
                if (left.kind != ValueKind.stringValue || right.kind != ValueKind.stringValue)
                    throw new YshTypeError("Glob comparison requires two Str values");
                if (left.stringValue.indexOf('\0') >= 0 || right.stringValue.indexOf('\0') >= 0)
                    throw new YshError("Glob comparison cannot contain NUL bytes");
                result = (fnmatch(right.stringValue.toStringz(), left.stringValue.toStringz(), 0) == 0) == (op == CompareOp.globMatch);
                break;
            case CompareOp.identical:
            case CompareOp.notIdentical:
                import yshd.value : sameIdentity;
                result = sameIdentity(left, right) == (op == CompareOp.identical);
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
    private string source_;
    private Lexer lexer_;
    private Token current_;
    private bool validateNested_;
    private size_t lastConsumedEnd_;
    private ShellOptions options_;

    this(string input, bool validateNested = false, ShellOptions options = null) {
        source_ = input;
        validateNested_ = validateNested;
        options_ = options;
        lexer_ = new Lexer(input, false, 0, true, options);
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
        lastConsumedEnd_ = lexer_.offset;
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

        while (isComparison(current_.kind) || (current_.kind == TokenKind.name && current_.text == "is")) {
            if (current_.kind == TokenKind.name && current_.text == "is") {
                advance();
                bool negated = current_.kind == TokenKind.notKeyword;
                if (negated) advance();
                operators ~= negated ? CompareOp.notIdentical : CompareOp.identical;
            } else if (current_.kind == TokenKind.tilde || current_.kind == TokenKind.bang) {
                bool negated = current_.kind == TokenKind.bang;
                if (negated) { advance(); require(TokenKind.tilde, "~"); }
                else advance();
                bool glob = current_.kind == TokenKind.tilde;
                if (glob) advance();
                operators ~= glob ? (negated ? CompareOp.notGlobMatch : CompareOp.globMatch)
                    : (negated ? CompareOp.notRegexMatch : CompareOp.regexMatch);
            } else if (current_.kind == TokenKind.notKeyword) {
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
                case TokenKind.approximateEqual:
                    operators ~= CompareOp.approximateEqual;
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
        if (kind == TokenKind.bang) return lexer_.peek().kind == TokenKind.tilde;
        switch (kind) {
        case TokenKind.tilde:
        case TokenKind.less:
        case TokenKind.greater:
        case TokenKind.lessEqual:
        case TokenKind.greaterEqual:
        case TokenKind.tripleEqual:
        case TokenKind.notDoubleEqual:
        case TokenKind.approximateEqual:
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
                left = new CallExpr(left, parseArguments(false));
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

    ParsedArguments parseArguments(bool allowBlock) {
        require(TokenKind.leftParen, "(");
        auto arguments = new ParsedArguments();
        size_t group;
        while (current_.kind != TokenKind.rightParen) {
            if (current_.kind == TokenKind.semicolon) {
                ++group;
                if (group > (allowBlock ? 2 : 1))
                    throw new ParseError("too many typed-argument groups");
                advance();
                continue;
            }
            if (group == 2) {
                if (arguments.block_ !is null) throw new ParseError("expected one block argument");
                arguments.block_ = parseTest();
            } else if (current_.kind == TokenKind.ellipsis) {
                advance();
                auto expression = parseTest();
                if (group == 1) arguments.named_ ~= NamedCallArgument("", expression, true);
                else arguments.positional_ ~= PositionalCallArgument(expression, true);
            } else if (current_.kind == TokenKind.name && lexer_.peek().kind == TokenKind.equal) {
                auto name = current_.text;
                advance();
                require(TokenKind.equal, "=");
                arguments.named_ ~= NamedCallArgument(name, parseTest(), false);
            } else {
                if (group == 1) throw new ParseError("expected named argument");
                arguments.positional_ ~= PositionalCallArgument(parseTest(), false);
            }
            if (current_.kind == TokenKind.comma) { advance(); continue; }
            if (current_.kind != TokenKind.semicolon) break;
        }
        require(TokenKind.rightParen, ")");
        return arguments;
    }

    private string parseCommandFragment() {
        auto start = current_.offset + 1;
        auto previousStrings = lexer_.expressionStrings;
        lexer_.expressionStrings = false;
        advance();
        int depth;
        while (current_.kind != TokenKind.eof) {
            if (current_.kind == TokenKind.rightParen && depth == 0) {
                auto command = source_[start .. current_.offset];
                lexer_.expressionStrings = previousStrings;
                advance();
                if (validateNested_) {
                    import yshd.program : parseProgram;
                    parseProgram(command, ReturnMode.shell, options_);
                }
                return command;
            }
            if (current_.kind == TokenKind.leftParen) ++depth;
            else if (current_.kind == TokenKind.rightParen) --depth;
            advance();
        }
        throw new ParseError("Unterminated command fragment");
    }

    private Expr parseAtom() {
        auto token = current_;
        switch (token.kind) {
        case TokenKind.caret:
            advance();
            if (current_.kind == TokenKind.leftBracket) {
                advance();
                auto expression = parseTest();
                require(TokenKind.rightBracket, "]");
                return new ExpressionClosureExpr(expression);
            }
            if (current_.kind == TokenKind.doubleQuoted)
                return new ExpressionClosureExpr(parseAtom());
            if (current_.kind == TokenKind.leftParen)
                return new CommandClosureExpr(parseCommandFragment());
            throw new ParseError("Expected [, double quote, or ( after ^");
        case TokenKind.slash:
            import yshd.eggex : parseEggex;
            auto regex = parseEggex(source_[token.offset .. $], options_);
            lastConsumedEnd_ = token.offset + regex.endOffset;
            lexer_ = new Lexer(source_, false, token.offset + regex.endOffset, true, options_);
            current_ = lexer_.next();
            return new EggexExpr(regex);
        case TokenKind.amp:
            advance();
            if (current_.kind != TokenKind.name) throw new ParseError("expected variable name after &");
            auto name = current_.text;
            advance();
            return new PlaceExpr(name);
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
            auto digits = token.text.replace("_", "");
            BigInt integer = 0;
            uint radix = 10;
            size_t first;
            if (digits.length > 2 && digits[0] == '0') {
                switch (digits[1]) {
                case 'b': radix = 2; first = 2; break;
                case 'o': radix = 8; first = 2; break;
                case 'x': radix = 16; first = 2; break;
                default: break;
                }
            }
            foreach (digit; digits[first .. $]) {
                uint value = digit >= '0' && digit <= '9' ? digit - '0'
                    : digit >= 'a' && digit <= 'f' ? digit - 'a' + 10 : digit - 'A' + 10;
                integer = integer * radix + value;
            }
            if (integer > BigInt(long.max)) throw new ParseError("integer constant is too large");
            return new LiteralExpr(Value.integer(integer));
        case TokenKind.floating:
            advance();
            return new LiteralExpr(Value.floating(parseFloating(token.text.replace("_", ""))));
        case TokenKind.doubleQuoted:
            advance();
            if (validateNested_) {
                import yshd.program : validateDoubleQuoted;
                validateDoubleQuoted(token.text, options_);
            }
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
            if (current_.kind == TokenKind.name || current_.kind == TokenKind.integer) {
                auto word = source_[token.offset .. current_.offset + current_.text.length];
                advance();
                return new DoubleQuotedExpr(word);
            }
            if (current_.kind == TokenKind.leftBrace) {
                int depth = 1;
                advance();
                while (current_.kind != TokenKind.eof && depth) {
                    if (current_.kind == TokenKind.leftBrace) ++depth;
                    if (current_.kind == TokenKind.rightBrace) --depth;
                    if (!depth) break;
                    advance();
                }
                if (depth) throw new ParseError("Unterminated braced substitution");
                auto word = source_[token.offset .. current_.offset + 1];
                advance();
                if (validateNested_) {
                    import yshd.program : validateDoubleQuoted;
                    validateDoubleQuoted(word, options_);
                }
                return new DoubleQuotedExpr(word);
            }
            if (current_.kind == TokenKind.doubleQuoted && current_.offset == token.offset + 1) {
                auto content = current_.text;
                advance();
                if (validateNested_) {
                    import yshd.program : validateDoubleQuoted;
                    validateDoubleQuoted(content, options_);
                }
                return new DoubleQuotedExpr(content);
            }
            if (current_.kind == TokenKind.leftParen) {
                auto start = current_.offset + 1;
                auto previousStrings = lexer_.expressionStrings;
                lexer_.expressionStrings = false;
                advance();
                int depth;
                while (current_.kind != TokenKind.eof) {
                    if (current_.kind == TokenKind.rightParen && depth == 0) {
                        auto command = source_[start .. current_.offset];
                        lexer_.expressionStrings = previousStrings;
                        advance();
                        if (validateNested_) {
                            import yshd.program : parseProgram;
                            parseProgram(command, ReturnMode.shell, options_);
                        }
                        return new CommandSubstitutionExpr(command);
                    }
                    if (current_.kind == TokenKind.leftParen) ++depth;
                    else if (current_.kind == TokenKind.rightParen) --depth;
                    advance();
                }
                throw new ParseError("unterminated command substitution");
            }
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
        case TokenKind.colon:
            advance();
            if (current_.kind == TokenKind.orIf) {
                advance();
                return new ShellArrayExpr("");
            }
            auto previousStrings = lexer_.expressionStrings;
            lexer_.expressionStrings = false;
            require(TokenKind.pipe, "|");
            auto start = current_.offset;
            int depth;
            while (current_.kind != TokenKind.eof) {
                if (current_.kind == TokenKind.pipe && depth == 0) {
                    auto words = source_[start .. current_.offset];
                    lexer_.expressionStrings = previousStrings;
                    advance();
                    if (validateNested_) {
                        import yshd.program : validateShellWords;
                        validateShellWords(words, options_);
                    }
                    return new ShellArrayExpr(words);
                }
                if (current_.kind == TokenKind.leftParen || current_.kind == TokenKind.leftBracket) ++depth;
                if (current_.kind == TokenKind.rightParen || current_.kind == TokenKind.rightBracket) --depth;
                advance();
            }
            throw new ParseError("unterminated shell array");
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
                } else if (current_.kind == TokenKind.doubleQuoted) {
                    key = parseAtom();
                    require(TokenKind.colon, ":");
                    value = parseTest();
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
    abstract Value read();
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

    override Value read() {
        return assignmentScope_ == AssignmentScope.global
            ? mem_.getGlobal(name_) : mem_.get(name_);
    }
}

private class ObjectAttributeResolvedPlace : ResolvedPlace {
    Value object;
    string name;
    this(Value object, string name) { this.object = object; this.name = name; }
    override Value read() { return objectAttribute(object, name, false); }
    override void assign(Value value) { object.objectValue.properties.set(name, value); }
}

private class ContainerResolvedPlace : ResolvedPlace {
    private Value object_;
    private Value index_;

    this(Value object, Value index) {
        object_ = object;
        index_ = index;
    }

    override Value read() {
        return (new SubscriptExpr(new LiteralExpr(object_), new LiteralExpr(index_))).eval(null);
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
        case ValueKind.placeValue:
        case ValueKind.eggexValue:
        case ValueKind.matchValue:
        case ValueKind.expressionValue:
        case ValueKind.commandValue:
        case ValueKind.objectValue:
        case ValueKind.builtinFunctionValue:
        case ValueKind.boundFunctionValue:
        case ValueKind.bashArrayValue:
        case ValueKind.bashAssocValue:
            throw new YshTypeError("obj[index] expected List or Dict");
        }
    }
}

ResolvedPlace resolvePlace(string source, Memory mem,
        AssignmentScope assignmentScope = AssignmentScope.local) {
    auto optionNumbers = mem.options.pushExpression();
    scope (exit) mem.options.pop(optionNumbers);
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
        if (object.kind == ValueKind.objectValue) return new ObjectAttributeResolvedPlace(object, attribute.name_);
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

void augmentPlace(string target, string op, string rhs, Memory mem,
        AssignmentScope assignmentScope) {
    auto place = resolvePlace(target, mem, assignmentScope);
    auto left = place.read();
    auto right = evaluate(rhs, mem);
    auto result = (new BinaryExpr(op, new LiteralExpr(left), new LiteralExpr(right))).eval(mem);
    place.assign(result);
}

/// Build the expression tree without looking up names or evaluating it.
void validateExpression(string source, ShellOptions options = null) {
    (new Parser(source, true, options)).parse();
}

/// Command collectors use the actual expression atom parser for constructs
/// with their own internal delimiters, rather than interpreting their tokens
/// as command separators (notably Eggex flags and multiline word arrays).
size_t expressionAtomEnd(string source, ShellOptions options = null) {
    auto parser = new Parser(source, true, options);
    parser.parseAtom();
    return parser.lastConsumedEnd_;
}

ParsedArguments parseTypedArguments(string source, bool validateNested = false, ShellOptions options = null) {
    auto parser = new Parser(source, validateNested, options);
    auto arguments = parser.parseArguments(true);
    if (parser.current_.kind != TokenKind.eof) throw new ParseError("unexpected token after typed arguments");
    return arguments;
}

void validateAssignmentTarget(string source) {
    auto target = (new Parser(source, true)).parse();
    if (cast(VariableExpr)target !is null ||
            cast(SubscriptExpr)target !is null ||
            cast(AttributeExpr)target !is null) return;
    throw new ParseError("assignment target must be a variable, subscript, or attribute");
}

Value evaluate(string source, Memory mem) {
    auto optionNumbers = mem.options.pushExpression();
    scope (exit) mem.options.pop(optionNumbers);
    auto parser = new Parser(source, false, mem.options);
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
