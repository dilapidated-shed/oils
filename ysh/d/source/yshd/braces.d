module yshd.braces;

import yshd.lexer : Token, TokenKind;

struct BraceWordPart {
    Token token;
    string source;
}

private struct BraceChoice {
    BraceNode[] parts;
}

private struct BraceNode {
    BraceWordPart part;
    BraceChoice[] choices;
}

private struct BraceFrame {
    BraceNode[] prefix;
    BraceChoice[] alternatives;
}

struct BraceWord {
    private BraceNode[] parts;

    @property bool present() const { return parts.length != 0; }

    BraceWordPart[][] expand() { return expandNodes(parts); }
}

private bool isName(string text) {
    if (!text.length) return false;
    foreach (index, ch; text) {
        if (ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) continue;
        if (index && ch >= '0' && ch <= '9') continue;
        return false;
    }
    return true;
}

/// Follow BraceDetect's whole-word rule. A malformed group prevents expansion
/// even when an adjacent group is valid. Only literal tokens are delimiters.
BraceWord detectBraceWord(BraceWordPart[] parts) {
    BraceFrame[] stack;
    BraceNode[] current;
    bool found;
    for (size_t i = 0; i < parts.length; ++i) {
        auto part = parts[i];
        if (part.token.kind == TokenKind.name && part.token.text == "{") {
            // The reference classifies {name} as one literal FD-variable token.
            if (i + 2 < parts.length && parts[i + 1].token.kind != TokenKind.charValue &&
                    isName(parts[i + 1].source) && parts[i + 2].token.kind == TokenKind.name &&
                    parts[i + 2].token.text == "}") {
                part.source ~= parts[i + 1].source ~ parts[i + 2].source;
                current ~= BraceNode(part);
                i += 2;
                continue;
            }
            stack ~= BraceFrame(current);
            current = [];
        } else if (part.token.kind == TokenKind.comma && stack.length) {
            stack[$ - 1].alternatives ~= BraceChoice(current);
            current = [];
        } else if (part.token.kind == TokenKind.name && part.token.text == "}") {
            if (!stack.length || !stack[$ - 1].alternatives.length) return BraceWord.init;
            auto frame = stack[$ - 1];
            stack.length--;
            frame.alternatives ~= BraceChoice(current);
            current = frame.prefix ~ BraceNode(BraceWordPart.init, frame.alternatives);
            found = true;
        } else current ~= BraceNode(part);
    }
    if (stack.length || !found) return BraceWord.init;
    return BraceWord(current);
}

private BraceWordPart[][] expandNodes(BraceNode[] nodes) {
    BraceWordPart[][] result = [[]];
    foreach (node; nodes) {
        if (!node.choices.length) {
            foreach (ref word; result) word ~= node.part;
            continue;
        }
        BraceWordPart[][] tails;
        foreach (choice; node.choices) tails ~= expandNodes(choice.parts);
        BraceWordPart[][] product;
        foreach (prefix; result) foreach (tail; tails) product ~= prefix ~ tail;
        result = product;
    }
    return result;
}

unittest {
    import std.stdio : File;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : YshError;

    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    executeProgram(q"GREASE
        suffix=kept
        printf '[%s]\n' $suffix{A,B} {id}_{1,2} 'comma,space '{c,d}
        printf '[%s]\n' $(printf V; printf 'visit\n' >&2){X,Y}
        printf 'unreachable' > /dev/{null,zero}
        echo redirect=$?
GREASE", mem);
    mem.options.set("ysh:all", true);
    executeProgram(q"GREASE
        test 0b29f = 0b29f
        proc collect{echo 0b29f{a,b}; }; collect
        func count() {return (42)}; echo $[count()]
GREASE", mem);
    output.rewind();
    errors.rewind();
    foreach (line; ["[keptA]\n", "[keptB]\n", "[{id}_1]\n", "[{id}_2]\n", "[comma,space c]\n",
            "[comma,space d]\n", "[VX]\n", "[VY]\n", "redirect=1\n", "0b29fa 0b29fb\n", "42\n"])
        assert(output.readln() == line);
    assert(output.readln() == "");
    assert(errors.readln() == "visit\n");
    assert(errors.readln() == "visit\n");
    assert(errors.readln() == "Brace expansion not allowed (try adding quotes)\n");
    assert(errors.readln() == "");

    foreach (source; ["echo x{", "echo x}", "echo x{a,b", "echo {a,b}''"]) {
        bool rejected;
        try { executeProgram(source, mem); }
        catch (YshError error) { rejected = error.status == 2; }
        assert(rejected, source);
    }
}
