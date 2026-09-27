module yshd.value;

import std.array : appender;
import std.bigint : BigInt, toDecimalString;
import std.format : format;

/// The first D slice mirrors the user-visible YSH data model in core/value.asdl.
enum ValueKind {
    nullValue,
    boolean,
    integer,
    floating,
    stringValue,
    list,
    dict,
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
    Value[] listValue;
    Value[string] dictValue;

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

    static Value list(Value[] value) {
        Value result;
        result.kind = ValueKind.list;
        result.listValue = value;
        return result;
    }

    static Value dict(Value[string] value) {
        Value result;
        result.kind = ValueKind.dict;
        result.dictValue = value;
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
    }
}

/// Mirrors ysh/val_ops.py:ToBool for the YSH data types translated so far.
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
    }
}

/// Mirrors ysh/val_ops.py:Stringify for the scalar data types in this slice.
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
        throw new YshTypeError("expected one of (Null Bool Int Float Str Eggex), got Dict");
    }
}

/// Mirrors ysh/val_ops.py:ExactlyEqual for translated data types.
bool exactlyEqual(Value left, Value right) {
    if (left.kind == ValueKind.floating || right.kind == ValueKind.floating) {
        throw new YshTypeError("Equality isn't defined on Float values (OILS-ERR-202)");
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
        foreach (index, item; left.listValue) {
            if (!exactlyEqual(item, right.listValue[index])) {
                return false;
            }
        }
        return true;
    case ValueKind.dict:
        if (left.dictValue.length != right.dictValue.length) {
            return false;
        }
        foreach (key, item; left.dictValue) {
            auto other = key in right.dictValue;
            if (other is null || !exactlyEqual(item, *other)) {
                return false;
            }
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

/// Stable diagnostic representation for this D port.  This is not yet YSH's
/// full J8 pretty-printer.
string repr(Value value) {
    final switch (value.kind) {
    case ValueKind.nullValue:
    case ValueKind.boolean:
    case ValueKind.integer:
    case ValueKind.floating:
        return stringify(value);
    case ValueKind.stringValue:
        return quoteString(value.stringValue);
    case ValueKind.list:
        auto buffer = appender!string();
        buffer.put("[");
        foreach (index, item; value.listValue) {
            if (index != 0) {
                buffer.put(", ");
            }
            buffer.put(repr(item));
        }
        buffer.put("]");
        return buffer.data;
    case ValueKind.dict:
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
            buffer.put(repr(item));
        }
        buffer.put("}");
        return buffer.data;
    }
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
}
