module yshd.io_ysh;

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

/// Render the scalar-word subset of builtin/io_ysh.py:Write.
/// Full word expansion and JSON/J8 encoders are separate translation work.
string renderWrite(string[] arguments, string separator = "\n",
        string ending = "\n") {
    string result;
    foreach (index, argument; arguments) {
        if (index != 0) {
            result ~= separator;
        }
        result ~= argument;
    }
    return result ~ ending;
}

unittest {
    assert(renderWrite(["a", "b"]) == "a\nb\n");
    assert(renderWrite(["a", "b"], "_", " END") == "a_b END");
    assert(renderWrite(["x"], "\n", "") == "x");
    assert(renderWrite([]) == "\n");
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
