module yshd.value;

import std.array : appender;
import std.bigint : BigInt, toDecimalString;
import std.format : format;

/// Mutable YSH List identity.
///
/// Keeping the payload behind a class reference is important: a copied Value
/// must still observe append/erase/mutation of the same List object.
class YshList {
    Value[] items;

    this(Value[] items = []) {
        this.items = items;
    }

    @property size_t length() const {
        return items.length;
    }

    void append(Value value) {
        items ~= value;
    }
}

/// Mutable, insertion-ordered YSH Dict identity.
///
/// D associative arrays alone are not sufficient because YSH exposes stable
/// key/value iteration order.  The fields table handles lookup while order
/// records first insertion.
class YshDict {
    private Value[string] fields;
    private string[] order;

    @property size_t length() const {
        return fields.length;
    }

    bool contains(string key) const {
        return (key in fields) !is null;
    }

    Value* find(string key) {
        return key in fields;
    }

    const(Value)* find(string key) const {
        return key in fields;
    }

    Value get(string key) {
        auto found = key in fields;
        if (found is null) {
            throw new YshError(format("Dict key not found: '%s'", key));
        }
        return *found;
    }

    Value getOr(string key, Value fallback) {
        auto found = key in fields;
        return found is null ? fallback : *found;
    }

    void set(string key, Value value) {
        if ((key in fields) is null) {
            order ~= key;
        }
        fields[key] = value;
    }

    void erase(string key) {
        if ((key in fields) is null) {
            return;
        }
        fields.remove(key);
        foreach (index, existing; order) {
            if (existing == key) {
                order = order[0 .. index] ~ order[index + 1 .. $];
                return;
            }
        }
    }

    void clear() {
        fields = null;
        order.length = 0;
    }

    string[] keys() const {
        return order.dup;
    }

    Value[] values() {
        Value[] result;
        result.reserve(order.length);
        foreach (key; order) {
            result ~= fields[key];
        }
        return result;
    }

    YshDict shallowCopy() {
        auto result = new YshDict();
        foreach (key; order) {
            result.set(key, fields[key]);
        }
        return result;
    }

    int opApply(scope int delegate(string, Value) dg) {
        foreach (key; order) {
            auto status = dg(key, fields[key]);
            if (status != 0) {
                return status;
            }
        }
        return 0;
    }
}

/// Runtime values translated from core/value.asdl.
///
/// More variants will be added until the complete ASDL surface reachable by
/// YSH is represented here.
enum ValueKind {
    nullValue,
    boolean,
    integer,
    floating,
    stringValue,
    list,
    dict,
    sliceValue,
    rangeValue,
    functionValue,
    procValue,
    placeValue,
    eggexValue,
    matchValue,
    expressionValue,
    commandValue,
    objectValue,
    builtinFunctionValue,
    builtinProcValue,
    boundFunctionValue,
    bashArrayValue,
    bashAssocValue,
    stdinValue,
}

class YshObject {
    YshObject prototype;
    YshDict properties;
    this(YshObject prototype, YshDict properties) {
        this.prototype = prototype;
        this.properties = properties;
    }
    Value* find(string name) {
        for (auto current = this; current !is null; current = current.prototype)
            if (auto value = current.properties.find(name)) return value;
        return null;
    }
}

string[] shellArrayValues(Value value) {
    auto keys = value.shellContainer.keys();
    if (value.kind == ValueKind.bashArrayValue) {
        import std.algorithm : sort;
        import std.conv : to;
        sort!((left, right) => to!long(left) < to!long(right))(keys);
    }
    string[] values;
    foreach (key; keys) values ~= value.shellContainer.find(key).stringValue;
    return values;
}

abstract class YshPlace {
    abstract void assign(Value value);
}

abstract class YshRegex {
    abstract string asEre();
    abstract RegexMatch search(string subject, long position = 0, bool leftMatch = false, bool useNotBol = true);
    abstract RegexMatch matchAffix(string subject, bool atEnd);
}

class RegexMatch {
    string subject;
    ptrdiff_t[] starts;
    ptrdiff_t[] ends;
    string[] names;
    Value delegate(Value)[] conversions;

    Value capture(Value selector, string action) {
        import std.conv : to;
        size_t index;
        if (selector.kind == ValueKind.integer) {
            if (selector.integerValue < 0 || selector.integerValue >= starts.length)
                throw new YshError("Capture group index out of range");
            index = to!size_t(selector.integerValue);
        } else if (selector.kind == ValueKind.stringValue) {
            bool found;
            foreach (offset, name; names) {
                if (name == selector.stringValue && name.length) { index = offset + 1; found = true; break; }
            }
            if (!found) throw new YshError("No such capture group: " ~ selector.stringValue);
        } else throw new YshTypeError("Capture group requires Int or Str");
        if (action == "start") return Value.integer(starts[index]);
        if (action == "end") return Value.integer(ends[index]);
        if (starts[index] == -1) return Value.nullValue();
        auto result = Value.str(subject[starts[index] .. ends[index]]);
        if (index && index <= conversions.length && conversions[index - 1] !is null)
            result = conversions[index - 1](result);
        return result;
    }
}

class YshError : Exception {
    int status;
    this(string message, int status = 3) {
        super(message);
        this.status = status;
    }
}

class UsageError : YshError {
    this(string message) { super(message, 2); }
}

class FatalRuntimeError : YshError {
    this(string message) { super(message, 1); }
}

class StructuredError : YshError {
    YshDict properties;
    this(int status, string message, YshDict properties) {
        super(message, status);
        this.properties = properties;
        properties.set("code", Value.integer(status));
        properties.set("message", Value.str(message));
    }
}

class YshTypeError : YshError {
    this(string message) {
        super(message);
    }
}

struct Value {
    // Value copies preserve identity; scalar constructors and literal
    // evaluation allocate a new identity, as reference ASDL value objects do.
    private static size_t nextScalarIdentity = 1;
    private size_t scalarIdentity;
    ValueKind kind = ValueKind.nullValue;
    bool booleanValue;
    BigInt integerValue;
    double floatValue;
    string stringValue;
    YshList listValue;
    YshDict dictValue;
    bool sliceHasLower;
    long sliceLower;
    bool sliceHasUpper;
    long sliceUpper;
    long rangeLower;
    long rangeUpper;
    Object callableValue;
    YshPlace placeValue;
    YshRegex regexValue;
    RegexMatch matchValue;
    YshObject objectValue;
    YshDict shellContainer;

    static Value shellArray(YshDict elements, bool associative = false) {
        Value result;
        result.kind = associative ? ValueKind.bashAssocValue : ValueKind.bashArrayValue;
        result.shellContainer = elements;
        return result;
    }

    static Value object(YshObject object) {
        Value result;
        result.kind = ValueKind.objectValue;
        result.objectValue = object;
        return result;
    }

    static Value builtin(Object callable) {
        Value result;
        result.kind = ValueKind.builtinFunctionValue;
        result.callableValue = callable;
        return result;
    }

    static Value builtinProc(Object callable) {
        Value result;
        result.kind = ValueKind.builtinProcValue;
        result.callableValue = callable;
        return result;
    }

    static Value bound(Object callable) {
        Value result;
        result.kind = ValueKind.boundFunctionValue;
        result.callableValue = callable;
        return result;
    }

    static Value closure(ValueKind kind, Object closure) {
        assert(kind == ValueKind.expressionValue || kind == ValueKind.commandValue);
        Value result;
        result.kind = kind;
        result.callableValue = closure;
        return result;
    }

    static Value eggex(YshRegex regex) {
        Value result;
        result.kind = ValueKind.eggexValue;
        result.regexValue = regex;
        return result;
    }

    static Value match(RegexMatch match) {
        Value result;
        result.kind = ValueKind.matchValue;
        result.matchValue = match;
        return result;
    }

    static Value place(YshPlace place) {
        Value result;
        result.kind = ValueKind.placeValue;
        result.placeValue = place;
        return result;
    }

    static Value nullValue() {
        Value result;
        result.kind = ValueKind.nullValue;
        return result;
    }

    static Value boolean(bool value) {
        Value result;
        result.scalarIdentity = nextScalarIdentity++;
        result.kind = ValueKind.boolean;
        result.booleanValue = value;
        return result;
    }

    static Value integer(BigInt value) {
        Value result;
        result.scalarIdentity = nextScalarIdentity++;
        result.kind = ValueKind.integer;
        result.integerValue = value;
        return result;
    }

    static Value integer(long value) {
        return integer(BigInt(value));
    }

    static Value floating(double value) {
        Value result;
        result.scalarIdentity = nextScalarIdentity++;
        result.kind = ValueKind.floating;
        result.floatValue = value;
        return result;
    }

    static Value str(string value) {
        Value result;
        result.scalarIdentity = nextScalarIdentity++;
        result.kind = ValueKind.stringValue;
        result.stringValue = value;
        return result;
    }

    static Value list(Value[] items) {
        return listRef(new YshList(items));
    }

    static Value listRef(YshList items) {
        Value result;
        result.kind = ValueKind.list;
        result.listValue = items;
        return result;
    }

    static Value dict() {
        return dictRef(new YshDict());
    }

    static Value dictRef(YshDict dictionary) {
        Value result;
        result.kind = ValueKind.dict;
        result.dictValue = dictionary;
        return result;
    }

    static Value slice(bool hasLower, long lower, bool hasUpper, long upper) {
        Value result;
        result.scalarIdentity = nextScalarIdentity++;
        result.kind = ValueKind.sliceValue;
        result.sliceHasLower = hasLower;
        result.sliceLower = lower;
        result.sliceHasUpper = hasUpper;
        result.sliceUpper = upper;
        return result;
    }

    /// Upper is exclusive, matching core/value.asdl Range and expr_eval.py.
    static Value range(long lower, long upper) {
        Value result;
        result.scalarIdentity = nextScalarIdentity++;
        result.kind = ValueKind.rangeValue;
        result.rangeLower = lower;
        result.rangeUpper = upper;
        return result;
    }

    Value literalCopy() {
        auto result = this;
        if (kind > ValueKind.nullValue && kind <= ValueKind.stringValue)
            result.scalarIdentity = nextScalarIdentity++;
        return result;
    }

    static Value callable(Object callable) {
        Value result;
        result.kind = ValueKind.functionValue;
        result.callableValue = callable;
        return result;
    }

    static Value proc(Object callable) {
        Value result;
        result.kind = ValueKind.procValue;
        result.callableValue = callable;
        return result;
    }

    static Value stdinSource() { Value result; result.kind = ValueKind.stdinValue; return result; }
}

bool sameIdentity(Value left, Value right) {
    if (left.kind != right.kind) return false;
    final switch (left.kind) {
    case ValueKind.nullValue: case ValueKind.stdinValue: return true;
    case ValueKind.boolean: case ValueKind.integer: case ValueKind.floating:
    case ValueKind.stringValue: case ValueKind.sliceValue: case ValueKind.rangeValue:
        return left.scalarIdentity == right.scalarIdentity;
    case ValueKind.list: return left.listValue is right.listValue;
    case ValueKind.dict: return left.dictValue is right.dictValue;
    case ValueKind.functionValue: case ValueKind.procValue:
    case ValueKind.expressionValue: case ValueKind.commandValue:
    case ValueKind.builtinFunctionValue: case ValueKind.boundFunctionValue:
    case ValueKind.builtinProcValue:
        return left.callableValue is right.callableValue;
    case ValueKind.objectValue: return left.objectValue is right.objectValue;
    case ValueKind.bashArrayValue: case ValueKind.bashAssocValue: return left.shellContainer is right.shellContainer;
    case ValueKind.placeValue: return left.placeValue is right.placeValue;
    case ValueKind.eggexValue: return left.regexValue is right.regexValue;
    case ValueKind.matchValue: return left.matchValue is right.matchValue;
    }
}

string kindName(Value value) {
    final switch (value.kind) {
    case ValueKind.nullValue:
        return "Null";
    case ValueKind.boolean:
        return "Bool";
    case ValueKind.integer:
        return "Int";
    case ValueKind.floating:
        return "Float";
    case ValueKind.stringValue:
        return "Str";
    case ValueKind.list:
        return "List";
    case ValueKind.dict:
        return "Dict";
    case ValueKind.sliceValue:
        return "Slice";
    case ValueKind.rangeValue:
        return "Range";
    case ValueKind.functionValue:
        return "Func";
    case ValueKind.procValue:
        return "Proc";
    case ValueKind.placeValue:
        return "Place";
    case ValueKind.eggexValue: return "Eggex";
    case ValueKind.matchValue: return "Match";
    case ValueKind.expressionValue: return "Expr";
    case ValueKind.commandValue: return "Command";
    case ValueKind.objectValue: return "Obj";
    case ValueKind.builtinFunctionValue: return "BuiltinFunc";
    case ValueKind.builtinProcValue: return "BuiltinProc";
    case ValueKind.boundFunctionValue: return "BoundFunc";
    case ValueKind.bashArrayValue: return "BashArray";
    case ValueKind.bashAssocValue: return "BashAssoc";
    case ValueKind.stdinValue: return "Stdin";
    }
}

bool toBool(Value value) {
    final switch (value.kind) {
    case ValueKind.nullValue:
        return false;
    case ValueKind.boolean:
        return value.booleanValue;
    case ValueKind.integer:
        return value.integerValue != 0;
    case ValueKind.floating:
        return value.floatValue != 0.0;
    case ValueKind.stringValue:
        return value.stringValue.length != 0;
    case ValueKind.list:
        return value.listValue.length != 0;
    case ValueKind.dict:
        return value.dictValue.length != 0;
    case ValueKind.sliceValue:
    case ValueKind.rangeValue:
        return true;
    case ValueKind.functionValue:
    case ValueKind.procValue:
    case ValueKind.placeValue:
    case ValueKind.eggexValue:
    case ValueKind.matchValue:
    case ValueKind.expressionValue:
    case ValueKind.commandValue:
    case ValueKind.objectValue:
    case ValueKind.builtinFunctionValue:
    case ValueKind.builtinProcValue:
    case ValueKind.boundFunctionValue:
    case ValueKind.bashArrayValue:
    case ValueKind.bashAssocValue:
    case ValueKind.stdinValue:
        return true;
    }
}

string stringify(Value value) {
    final switch (value.kind) {
    case ValueKind.nullValue:
        return "null";
    case ValueKind.boolean:
        return value.booleanValue ? "true" : "false";
    case ValueKind.integer:
        return toDecimalString(value.integerValue);
    case ValueKind.floating:
        import std.math : isNaN, isInfinity;
        import std.string : indexOf;
        // val_ops.Stringify uses Python's str(Float), distinct from the
        // uppercase nonfinite spellings of J8 and diagnostic pretty printing.
        if (isNaN(value.floatValue)) return "nan";
        if (isInfinity(value.floatValue)) return value.floatValue < 0 ? "-inf" : "inf";
        // Match the reference FloatToStr precision before preserving .0.
        auto text = format("%.16g", value.floatValue);
        if (text.indexOf('.') < 0 && text.indexOf('e') < 0 && text.indexOf('E') < 0) text ~= ".0";
        return text;
    case ValueKind.stringValue:
        return value.stringValue;
    case ValueKind.list:
        throw new YshTypeError("got a List, which can't be stringified");
    case ValueKind.dict:
        throw new YshTypeError(
            "expected one of (Null Bool Int Float Str Eggex), got Dict");
    case ValueKind.sliceValue:
        throw new YshTypeError("can't stringify Slice");
    case ValueKind.rangeValue:
        throw new YshTypeError("can't stringify Range");
    case ValueKind.functionValue:
        throw new YshTypeError("can't stringify Func");
    case ValueKind.procValue:
        throw new YshTypeError("can't stringify Proc");
    case ValueKind.placeValue:
        throw new YshTypeError("can't stringify Place");
    case ValueKind.eggexValue:
        return value.regexValue.asEre();
    case ValueKind.matchValue:
        throw new YshTypeError("can't stringify Match");
    case ValueKind.expressionValue:
    case ValueKind.commandValue:
    case ValueKind.objectValue:
    case ValueKind.builtinFunctionValue:
    case ValueKind.builtinProcValue:
    case ValueKind.boundFunctionValue:
    case ValueKind.bashArrayValue:
    case ValueKind.bashAssocValue:
    case ValueKind.stdinValue:
        throw new YshTypeError("can't stringify " ~ kindName(value));
    }
}

/// Mirrors ysh/val_ops.py:ExactlyEqual for the translated data types.
bool exactlyEqual(Value left, Value right) {
    if (left.kind == ValueKind.floating || right.kind == ValueKind.floating) {
        throw new YshTypeError(
            "Equality isn't defined on Float values (OILS-ERR-202)");
    }

    if (left.kind != right.kind) {
        return false;
    }

    final switch (left.kind) {
    case ValueKind.nullValue:
        return true;
    case ValueKind.boolean:
        return left.booleanValue == right.booleanValue;
    case ValueKind.integer:
        return left.integerValue == right.integerValue;
    case ValueKind.floating:
        assert(false, "Float handled above");
    case ValueKind.stringValue:
        return left.stringValue == right.stringValue;
    case ValueKind.list:
        if (left.listValue.length != right.listValue.length) {
            return false;
        }
        foreach (index, item; left.listValue.items) {
            if (!exactlyEqual(item, right.listValue.items[index])) {
                return false;
            }
        }
        return true;
    case ValueKind.dict:
        if (left.dictValue.length != right.dictValue.length) {
            return false;
        }
        foreach (key, item; left.dictValue) {
            auto other = right.dictValue.find(key);
            if (other is null || !exactlyEqual(item, *other)) {
                return false;
            }
        }
        return true;
    case ValueKind.sliceValue:
        throw new YshTypeError("Equality isn't defined on Slice values");
    case ValueKind.rangeValue:
        throw new YshTypeError("Equality isn't defined on Range values");
    case ValueKind.functionValue:
    case ValueKind.procValue:
    case ValueKind.placeValue:
    case ValueKind.eggexValue:
    case ValueKind.matchValue:
    case ValueKind.expressionValue:
    case ValueKind.commandValue:
    case ValueKind.objectValue:
    case ValueKind.builtinFunctionValue:
    case ValueKind.builtinProcValue:
    case ValueKind.boundFunctionValue:
    case ValueKind.stdinValue:
        throw new YshTypeError("Equality isn't defined on " ~ kindName(left) ~ " values");
    case ValueKind.bashArrayValue:
    case ValueKind.bashAssocValue:
        if (left.shellContainer.length != right.shellContainer.length) return false;
        foreach (key, item; left.shellContainer) {
            auto other = right.shellContainer.find(key);
            if (other is null || item.stringValue != other.stringValue) return false;
        }
        return true;
    }
}

private string quoteString(string value) {
    auto buffer = appender!string();
    buffer.put('"');
    foreach (char c; value) {
        switch (c) {
        case '"':
            buffer.put("\\\"");
            break;
        case '\\':
            buffer.put("\\\\");
            break;
        case '\n':
            buffer.put("\\n");
            break;
        case '\r':
            buffer.put("\\r");
            break;
        case '\t':
            buffer.put("\\t");
            break;
        default:
            buffer.put(c);
            break;
        }
    }
    buffer.put('"');
    return buffer.data;
}

private string reprWithActive(Value value, ref bool[Object] active) {
    final switch (value.kind) {
    case ValueKind.nullValue:
    case ValueKind.boolean:
    case ValueKind.integer:
    case ValueKind.floating:
        return stringify(value);
    case ValueKind.stringValue:
        return quoteString(value.stringValue);
    case ValueKind.list:
        Object identity = value.listValue;
        if (identity in active) {
            return "[...]";
        }
        active[identity] = true;
        scope (exit) active.remove(identity);

        auto buffer = appender!string();
        buffer.put("[");
        foreach (index, item; value.listValue.items) {
            if (index != 0) {
                buffer.put(", ");
            }
            buffer.put(reprWithActive(item, active));
        }
        buffer.put("]");
        return buffer.data;

    case ValueKind.dict:
        Object identity = value.dictValue;
        if (identity in active) {
            return "{...}";
        }
        active[identity] = true;
        scope (exit) active.remove(identity);

        auto buffer = appender!string();
        buffer.put("{");
        bool first = true;
        foreach (key, item; value.dictValue) {
            if (!first) {
                buffer.put(", ");
            }
            first = false;
            buffer.put(quoteString(key));
            buffer.put(": ");
            buffer.put(reprWithActive(item, active));
        }
        buffer.put("}");
        return buffer.data;

    case ValueKind.sliceValue:
        auto lower = value.sliceHasLower ? format("%s", value.sliceLower) : "";
        auto upper = value.sliceHasUpper ? format("%s", value.sliceUpper) : "";
        return lower ~ ":" ~ upper;
    case ValueKind.rangeValue:
        return format("%s..<%s", value.rangeLower, value.rangeUpper);
    case ValueKind.functionValue:
        return "<func>";
    case ValueKind.procValue:
        return "<proc>";
    case ValueKind.placeValue:
        return "<Place>";
    case ValueKind.eggexValue: return "<Eggex>";
    case ValueKind.matchValue: return "<Match>";
    case ValueKind.expressionValue: return "<Expr>";
    case ValueKind.commandValue: return "<Command>";
    case ValueKind.objectValue: return "<Obj>";
    case ValueKind.builtinFunctionValue: return "<BuiltinFunc>";
    case ValueKind.builtinProcValue: return "<BuiltinProc>";
    case ValueKind.boundFunctionValue: return "<BoundFunc>";
    case ValueKind.bashArrayValue: return "<BashArray>";
    case ValueKind.bashAssocValue: return "<BashAssoc>";
    case ValueKind.stdinValue: return "<Stdin>";
    }
}

/// Stable diagnostic representation for the D port. This remains separate from
/// the full J8/display translation, but already handles recursive containers.
string repr(Value value) {
    bool[Object] active;
    return reprWithActive(value, active);
}

unittest {
    assert(!toBool(Value.nullValue()));
    assert(!toBool(Value.integer(0)));
    assert(toBool(Value.integer(1)));
    assert(!toBool(Value.str("")));
    assert(toBool(Value.str("x")));
    assert(!toBool(Value.list([])));
    assert(toBool(Value.list([Value.integer(1)])));

    assert(exactlyEqual(Value.integer(42), Value.integer(42)));
    assert(!exactlyEqual(Value.integer(42), Value.str("42")));
    assert(exactlyEqual(
        Value.list([Value.integer(1), Value.str("x")]),
        Value.list([Value.integer(1), Value.str("x")])));

    auto dictionary = Value.dict();
    dictionary.dictValue.set("b", Value.integer(2));
    dictionary.dictValue.set("a", Value.integer(1));
    dictionary.dictValue.set("b", Value.integer(3));
    assert(dictionary.dictValue.keys() == ["b", "a"]);
    assert(repr(dictionary) == "{\"b\": 3, \"a\": 1}");

    auto recursiveList = Value.list([]);
    recursiveList.listValue.append(recursiveList);
    assert(repr(recursiveList) == "[[...]]");

    auto recursiveDict = Value.dict();
    recursiveDict.dictValue.set("self", recursiveDict);
    assert(repr(recursiveDict) == "{\"self\": {...}}");
}
