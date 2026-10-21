module yshd.split;

import std.array : join;
import std.string : indexOf, replace;

/// osh/split.py:IfsSplitterState combines literal and split fragments without
/// losing empty quoted words or the delimiter bytes needed by read's last
/// variable. All character tests are byte tests, including invalid UTF-8.
class IfsSplitter {
    private enum State { start, whitespace, black, escaped }
    private string whitespace;
    private string other;
    private State state;
    private string[] words;
    private string[] fragments;
    private string characters;
    private string pendingWhitespace;
    bool allowEscape;
    bool globEscape;
    long maximumSplit = -1;

    this(string ifs) {
        foreach (character; ifs) {
            if (" \t\n".indexOf(character) >= 0) whitespace ~= character;
            else other ~= character;
        }
    }

    private void flushCharacters() {
        if (!characters.length) return;
        fragments ~= globEscape ? characters.replace("\\", "\\@") : characters;
        characters = "";
    }

    private void generateWord() {
        flushCharacters();
        words ~= fragments.join();
        fragments = [];
        if (maximumSplit >= 0 && pendingWhitespace.length) {
            characters ~= pendingWhitespace;
            pendingWhitespace = "";
        }
    }

    void pushLiteral(string source) {
        if (state == State.whitespace) generateWord();
        else flushCharacters();
        fragments ~= source;
        state = State.black;
    }

    void pushFragment(string source) {
        foreach (character; source) {
            if (state == State.escaped) {
                // An escaped byte bypasses delimiter classification.
            } else if (maximumSplit >= 0 && cast(long)words.length == maximumSplit + 1) {
                if (allowEscape && character == '\\') { state = State.escaped; continue; }
                if (whitespace.indexOf(character) >= 0 && state == State.start) {
                    characters ~= character;
                    continue;
                }
            } else if (allowEscape && character == '\\') {
                if (state == State.whitespace) generateWord();
                state = State.escaped;
                continue;
            } else if (whitespace.indexOf(character) >= 0) {
                if (state != State.start) {
                    if (cast(long)words.length == maximumSplit) pendingWhitespace ~= character;
                    state = State.whitespace;
                }
                continue;
            } else if (other.indexOf(character) >= 0) {
                if (cast(long)words.length == maximumSplit) pendingWhitespace ~= character;
                generateWord();
                state = State.start;
                continue;
            }
            if (state == State.whitespace) generateWord();
            characters ~= character;
            state = State.black;
        }
    }

    string[] finish() {
        if (state == State.whitespace || state == State.black) {
            generateWord();
            if (maximumSplit >= 0 && cast(long)words.length == maximumSplit + 2) {
                auto last = words[$ - 1];
                words.length--;
                while (last.length && whitespace.indexOf(last[$ - 1]) >= 0) last = last[0 .. $ - 1];
                words[$ - 1] ~= last;
            }
            state = State.start;
        }
        return words;
    }
}

string[] splitWords(string source, string ifs) {
    auto splitter = new IfsSplitter(ifs);
    splitter.allowEscape = true;
    splitter.pushFragment(source);
    return splitter.finish();
}

unittest {
    assert(splitWords("", " \t\n") == []);
    assert(splitWords(" \tone two\n", " \t\n") == ["one", "two"]);
    assert(splitWords(" a : : b ", " :") == ["a", "", "b"]);
    assert(splitWords(" :: ", " :") == ["", ""]);
    assert(splitWords("a\\ b", " ") == ["a b"]);
    assert(splitWords("a\xffb", "b") == ["a\xff"]);
    assert(splitWords("a b", "") == ["a b"]);
    auto splitter = new IfsSplitter(" ");
    splitter.pushFragment("a ");
    splitter.pushLiteral("");
    assert(splitter.finish() == ["a", ""]);
    auto limited = new IfsSplitter(" :");
    limited.maximumSplit = 1;
    limited.pushFragment(" a : b : c : ");
    assert(limited.finish() == ["a", "b : c :"]);
}
