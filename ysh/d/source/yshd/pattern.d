module yshd.pattern;

import std.string : toStringz;
import yshd.libc_patterns : fnmatch;
version (linux) import yshd.libc_patterns : FNM_CASEFOLD;
import yshd.value : YshError;

/// Quoting belongs to each fragment, not to the whole concatenated word.
/// Keep it until a consumer chooses literal text or a shell pattern.
struct WordFragment {
    string text;
    bool quoted;
}

struct ScalarWord {
    WordFragment[] fragments;

    void append(string text, bool quoted) {
        fragments ~= WordFragment(text, quoted);
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
