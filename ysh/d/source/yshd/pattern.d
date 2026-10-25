module yshd.pattern;

import std.string : toStringz;
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
}

struct ScalarWord {
    WordFragment[] fragments;

    void append(string text, bool quoted, bool splitEligible = false) {
        fragments ~= WordFragment(text, quoted, splitEligible);
    }

    string text() const {
        string result;
        foreach (fragment; fragments) result ~= fragment.text;
        return result;
    }

    string fnmatchPattern() const {
        string result;
        foreach (fragment; fragments) {
            foreach (char ch; fragment.text) {
                // QUOTE_FNMATCH escapes only quoted fragments. Unquoted
                // expansion bytes retain libc fnmatch's pattern meaning.
                import std.string : indexOf;
                if (fragment.quoted && "\\*?[]-:!()|".indexOf(ch) >= 0)
                    result ~= '\\';
                result ~= ch;
            }
        }
        return result;
    }

    string erePattern() const {
        import std.string : indexOf;
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
ScalarWord[] splitShellWord(ScalarWord word, string ifs) {
    import std.string : indexOf;
    ScalarWord[] fields;
    ScalarWord field;
    bool present, whitespace;
    void emit() { fields ~= field; field = ScalarWord.init; present = false; whitespace = false; }
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

string[] expandShellWord(ScalarWord word, Memory mem, bool staticWord = true) {
    import yshd.glob : globPaths;
    import yshd.value : ValueKind, FatalRuntimeError;
    import std.string : indexOf;
    ScalarWord[] fields;
    if (mem.options.get("simple_word_eval")) {
        // Simple word evaluation implicitly quotes scalar substitutions;
        // literal glob operators still expand.
        foreach (ref fragment; word.fragments) if (fragment.splitEligible) fragment.quoted = true;
        fields = [word];
    }
    else {
        auto cell = mem.findDynamicCell("IFS");
        auto ifs = cell is null ? " \t\n" : cell.value.stringValue;
        fields = splitShellWord(word, ifs);
    }
    string[] result;
    foreach (field; fields) {
        bool pattern;
        bool leftBracket;
        foreach (fragment; field.fragments) if (!fragment.quoted)
            foreach (ch; fragment.text) {
                if (ch == '*' || ch == '?') pattern = true;
                else if (ch == '[') leftBracket = true;
                else if (ch == ']' && leftBracket) pattern = true;
            }
        if (!pattern || mem.options.get("noglob") || (mem.options.get("simple_word_eval") && !staticWord)) {
            result ~= field.text(); continue;
        }
        auto paths = globPaths(field.fnmatchPattern(), mem);
        if (paths.length) result ~= paths;
        else if (mem.options.get("failglob")) throw new FatalRuntimeError("Pattern matched no files: " ~ field.text());
        else if (!mem.options.get("nullglob")) result ~= field.text();
    }
    return result;
}

bool matchesShellPattern(ScalarWord word, string subject, bool ignoreCase) {
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
    ScalarWord word;
    word.append("*", true);
    word.append(".h", false);
    assert(matchesShellPattern(word, "*.h", false));
    assert(!matchesShellPattern(word, "header.h", false));
    ScalarWord mixed;
    mixed.append("prefix[", true);
    mixed.append("*", false);
    mixed.append("]", true);
    assert(matchesShellPattern(mixed, "prefix[abc]", false));
    ScalarWord slash;
    slash.append("a\\*", false);
    assert(!matchesShellPattern(slash, "a\\tail", false));
    assert(matchesShellPattern(slash, "a*", false));
}
