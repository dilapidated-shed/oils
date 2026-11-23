module yshd.pattern;

import std.array : join;
import std.string : indexOf, toStringz;
import yshd.libc_patterns : fnmatch;
version (linux) import yshd.libc_patterns : FNM_CASEFOLD;
import yshd.value : YshError;
import yshd.state : Memory;

/// Quoting belongs to each fragment, not to the whole concatenated word.
/// Keep it until a consumer chooses literal text or a shell pattern.
struct WordFragment {
    string text;
    bool quoted;
    bool splitEligible;
    bool arrayPart;
    string[] elements;
}

struct ShellWord {
    WordFragment[] fragments;
    bool hasArray;

    void append(string text, bool quoted, bool splitEligible = false) {
        fragments ~= WordFragment(text, quoted, splitEligible);
    }

    void appendArray(string[] elements) {
        fragments ~= WordFragment("", true, false, true, elements);
        hasArray = true;
    }

    string text() const {
        string result;
        foreach (fragment; fragments)
            result ~= fragment.arrayPart ? fragment.elements.join(" ") : fragment.text;
        return result;
    }

    private ShellWord[] argumentFrames() {
        ShellWord[] frames = [ShellWord.init];
        foreach (fragment; fragments) {
            if (!fragment.arrayPart) {
                frames[$ - 1].fragments ~= fragment;
                continue;
            }
            foreach (index, element; fragment.elements) {
                if (index) frames ~= ShellWord.init;
                frames[$ - 1].append(element, true);
            }
        }
        return frames;
    }

    private bool hasGlob(bool literalOnly = false) const {
        bool leftBracket;
        foreach (fragment; fragments) {
            if (fragment.quoted || (literalOnly && fragment.splitEligible)) continue;
            foreach (ch; fragment.text) {
                if (ch == '*' || ch == '?') return true;
                if (ch == '[') leftBracket = true;
                else if (ch == ']' && leftBracket) return true;
            }
        }
        return false;
    }

    string fnmatchPattern() const {
        string result;
        foreach (fragment; fragments) {
            foreach (char ch; fragment.text) {
                // QUOTE_FNMATCH escapes only quoted fragments. Unquoted
                // expansion bytes retain libc fnmatch's pattern meaning.
                if (fragment.quoted && "\\*?[]-:!()|".indexOf(ch) >= 0)
                    result ~= '\\';
                result ~= ch;
            }
        }
        return result;
    }

    string erePattern() const {
        string result;
        foreach (fragment; fragments) foreach (char ch; fragment.text) {
            if (fragment.quoted && ".^$*+?{}[]\\|()".indexOf(ch) >= 0) result ~= '\\';
            result ~= ch;
        }
        return result;
    }
}

/// osh/split.py:IFS splitting applies to unquoted expansion bytes, never to
/// literal text or quoted fragments. Preserve fragment quoting for globbing.
ShellWord[] splitShellWord(ShellWord word, string ifs) {
    ShellWord[] fields;
    ShellWord field;
    bool present, whitespace;
    void emit() { fields ~= field; field = ShellWord.init; present = false; whitespace = false; }
    foreach (fragment; word.fragments) {
        if (!fragment.text.length && fragment.quoted) {
            if (whitespace && present) emit();
            present = true;
            field.append("", true);
        }
        foreach (i, ch; fragment.text) {
            bool delimiter = fragment.splitEligible && !fragment.quoted && ifs.indexOf(ch) >= 0;
            if (delimiter && (ch == ' ' || ch == '\t' || ch == '\n')) {
                if (present) whitespace = true;
            } else if (delimiter) {
                emit(); // Non-whitespace IFS delimiters also delimit empty fields.
            } else {
                if (whitespace && present) emit();
                field.append(fragment.text[i .. i + 1], fragment.quoted);
                present = true;
            }
        }
    }
    if (present) fields ~= field;
    return fields;
}

string[] expandShellWord(ShellWord word, Memory mem, bool commandPosition = false) {
    import yshd.glob : globPaths;
    import yshd.value : FatalRuntimeError;
    bool simple = mem.options.get("simple_word_eval");
    bool noGlob = mem.options.get("noglob");
    string[] result;

    void expandPattern(string pattern, string literal) {
        if (!noGlob) {
            auto paths = globPaths(pattern, mem);
            if (paths.length) { result ~= paths; return; }
            if (mem.options.get("failglob")) throw new FatalRuntimeError("Pattern matched no files: " ~ literal);
            if (mem.options.get("nullglob")) return;
        }
        result ~= simple ? unescapeGlob(literal) : literal;
    }

    // A literal glob operator opts the whole evaluated word into string
    // evaluation. Substituted bytes alone never opt in. Strict array checks
    // happen before glob options such as noglob, just as in Oils.
    if (simple && !commandPosition && word.hasGlob(true)) {
        if (word.hasArray && mem.options.get("strict_array"))
            throw new FatalRuntimeError("This word should yield a string, but it contains an array");
        auto text = word.text();
        expandPattern(text, text);
        return result;
    }

    foreach (frame; word.hasArray ? word.argumentFrames() : [word]) {
        if (!frame.fragments.length) continue;
        if (simple) { result ~= frame.text(); continue; }
        auto cell = mem.findDynamicCell("IFS");
        auto ifs = cell is null ? " \t\n" : cell.value.stringValue;
        foreach (field; splitShellWord(frame, ifs)) {
            if (field.hasGlob()) expandPattern(field.fnmatchPattern(), field.text());
            else result ~= field.text();
        }
    }
    return result;
}

private string unescapeGlob(string pattern) {
    import yshd.value : InterpreterFailure;
    string result;
    for (size_t index; index < pattern.length; ++index) {
        char ch = pattern[index];
        if (ch == '\\' && index + 1 < pattern.length) {
            ch = pattern[++index];
            if (ch == '@') ch = '\\';
            else if ("\\*?[]-:!()|".indexOf(ch) < 0)
                throw new InterpreterFailure("Unexpected escaped character in glob pattern");
        }
        result ~= ch;
    }
    return result;
}

bool matchesShellPattern(ShellWord word, string subject, bool ignoreCase) {
    auto pattern = word.fnmatchPattern();
    // Match libc's byte-string boundary explicitly rather than truncating.
    if (pattern.canFindNul() || subject.canFindNul())
        throw new YshError("shell patterns cannot contain NUL bytes");
    version (linux) enum caseFold = FNM_CASEFOLD;
    else enum caseFold = 0;
    version (linux) {} else {
        if (ignoreCase) throw new YshError("nocasematch is not translated on this target");
    }
    return fnmatch(pattern.toStringz(), subject.toStringz(), ignoreCase ? caseFold : 0) == 0;
}

private bool canFindNul(string value) {
    foreach (char ch; value) if (ch == '\0') return true;
    return false;
}

unittest {
    ShellWord word;
    word.append("*", true);
    word.append(".h", false);
    assert(matchesShellPattern(word, "*.h", false));
    assert(!matchesShellPattern(word, "header.h", false));
    ShellWord mixed;
    mixed.append("prefix[", true);
    mixed.append("*", false);
    mixed.append("]", true);
    assert(matchesShellPattern(mixed, "prefix[abc]", false));
    ShellWord slash;
    slash.append("a\\*", false);
    assert(!matchesShellPattern(slash, "a\\tail", false));
    assert(matchesShellPattern(slash, "a*", false));
}
