module yshd.io_ysh;

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
}
