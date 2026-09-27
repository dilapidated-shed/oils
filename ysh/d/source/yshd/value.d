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

    Value get(string key) const {
        auto found = key in fields;
        if (found is null) {
            throw new YshError(format("Dict key not found: '%s'", key));
        }
        return *found;
    }

    Value getOr(string key, Value fallback) const {
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

    Value[] values() const {
        Value[] result;
        result.reserve(order.length);
        foreach (key; order) {
            result ~= fields[key];
        }
        return result;
    }

    YshDict shallowCopy() const {
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
}

class YshError : Exception {
    this(string message) {
        super(message);
    }
}

class YshTypeError : YshError {
    this(string message) {
        super(message);
    }
}

struct Value {
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

    static Value nullValue() {
        Value result;
        result.kind = ValueKind.nullValue;
        return result;
    }

    static Value boolean(bool value) {
        Value result;
        result.kind = ValueKind.boolean;
        result.booleanValue = value;
        return result;
    }

    static Value integer(BigInt value) {
        Value result;
        result.kind = ValueKind.integer;
        result.integerValue = value;
        return result;
    }

    static Value integer(long value) {
        return integer(BigInt(value));
    }

    static Value floating(double value) {
        Value result;
        result.kind = ValueKind.floating;
        result.floatValue = value;
        return result;
    }

    static Value str(string value) {
        Value result;
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
        result.kind = ValueKind.rangeValue;
        result.rangeLower = lower;
        result.rangeUpper = upper;
        return result;
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
        return format("%s", value.floatValue);
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
