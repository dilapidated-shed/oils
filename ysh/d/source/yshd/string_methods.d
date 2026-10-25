module yshd.string_methods;

import std.string : startsWith, endsWith, indexOf;
import std.utf : decode, decodeBack, UTFException;
import yshd.value : Value, ValueKind, StructuredError, YshDict, YshTypeError;

private bool isReferenceWhitespace(dchar character) {
    // osh/string_ops.py:_IsSpace intentionally supports this limited set.
    return character == ' ' || (character >= '\t' && character <= '\r') ||
        character == 0x00a0 || character == 0xfeff;
}

private struct AffixRange {
    bool matched;
    size_t start;
    size_t end;
}

private AffixRange matchAffix(string source, Value pattern, bool atEnd) {
    if (pattern.kind == ValueKind.stringValue) {
        auto text = pattern.stringValue;
        if (atEnd && source.endsWith(text))
            return AffixRange(true, source.length - text.length, source.length);
        if (!atEnd && source.startsWith(text))
            return AffixRange(true, 0, text.length);
    } else if (pattern.kind == ValueKind.eggexValue) {
        auto match = pattern.regexValue.matchAffix(source, atEnd);
        if (match !is null)
            return AffixRange(true, match.starts[0], match.ends[0]);
    } else throw new YshTypeError("Expected pattern to be Eggex or Str");
    auto position = atEnd ? source.length : 0;
    return AffixRange(false, position, position);
}

bool hasStringAffix(string source, Value pattern, bool atEnd) {
    return matchAffix(source, pattern, atEnd).matched;
}

string trimStringAffixes(string source, bool trimStart, bool trimEnd, Value[] patterns) {
    size_t start;
    auto end = source.length;
    if (patterns.length) {
        // Both matches use the original string, even when their ranges overlap.
        if (trimStart) start = matchAffix(source, patterns[0], false).end;
        if (trimEnd) end = matchAffix(source, patterns[0], true).start;
    } else {
        try {
            if (trimStart) while (start < source.length) {
                auto next = start;
                if (!isReferenceWhitespace(decode(source, next))) break;
                start = next;
            }
            if (trimEnd) while (end > 0) {
                auto remaining = source[0 .. end];
                if (!isReferenceWhitespace(decodeBack(remaining))) break;
                end = remaining.length;
            }
        } catch (UTFException error) {
            throw new StructuredError(3, "Invalid UTF-8 in whitespace trim", new YshDict());
        }
    }
    return start < end ? source[start .. end] : "";
}

Value[] splitStringByPattern(string source, Value separator, long count) {
    if (separator.kind != ValueKind.stringValue && separator.kind != ValueKind.eggexValue)
        throw new YshTypeError("Expected separator to be Eggex or Str");
    if (!source.length) return [];
    bool regularExpression = separator.kind == ValueKind.eggexValue;
    if (!regularExpression && !separator.stringValue.length)
        throw new StructuredError(3, "separator must be non-empty", new YshDict());
    if (regularExpression && source.indexOf('\0') >= 0)
        throw new StructuredError(3, "cannot split a string with a NUL byte", new YshDict());

    size_t cursor;
    Value[] chunks;
    while (cursor < source.length && count != 0) {
        size_t start, end;
        if (regularExpression) {
            auto match = separator.regexValue.search(source, cursor, false, false);
            if (match is null) break;
            start = match.starts[0];
            end = match.ends[0];
            if (start == end)
                throw new StructuredError(3, "eggex separators should never match the empty string", new YshDict());
        } else {
            auto offset = source[cursor .. $].indexOf(separator.stringValue);
            if (offset < 0) break;
            start = cursor + offset;
            end = start + separator.stringValue.length;
        }
        chunks ~= Value.str(source[cursor .. start]);
        cursor = end;
        if (count > 0) --count;
    }
    chunks ~= Value.str(source[cursor .. $]);
    return chunks;
}

unittest {
    import yshd.expr : evaluate;
    import yshd.state : Memory;
    import yshd.value : exactlyEqual, YshError;
    assert(trimStringAffixes("  abc  ", true, true, []) == "abc");
    assert(trimStringAffixes("  abc  ", false, true, []) == "  abc");
    assert(trimStringAffixes("  abc  ", true, false, []) == "abc  ");
    assert(trimStringAffixes(" \0 ", true, true, []) == "\0");
    assert(trimStringAffixes("\u00a0\ufeffabc\ufeff\u00a0", true, true, []) == "abc");
    assert(trimStringAffixes("\u2003abc\u2003", true, true, []) == "\u2003abc\u2003");
    assert(trimStringAffixes(" a\xffb ", true, true, []) == "a\xffb");
    foreach (source; ["\xffabc", "abc\xff"]) {
        bool rejected;
        try { trimStringAffixes(source, true, true, []); }
        catch (StructuredError error) { rejected = error.status == 3; }
        assert(rejected);
    }
    assert(trimStringAffixes("ababa", true, true, [Value.str("aba")]) == "");
    assert(splitStringByPattern("", Value.str(""), 0).length == 0);
    assert(splitStringByPattern("a\0b", Value.str("\0"), -1).length == 2);
    auto mem = new Memory();
    assert(evaluate("'AbC'.startsWith(/ 'a' ; i /)", mem).booleanValue);
    assert(evaluate("'AbC'.endsWith(/ 'c' ; i /)", mem).booleanValue);
    evaluate("'keep42' ~ / <capture d+> /", mem);
    auto savedMatch = mem.regexMatch;
    evaluate("'abc'.startsWith(/ <capture 'a'> /)", mem);
    assert(mem.regexMatch is savedMatch);
    auto result = evaluate("'a,b;c'.split(/ ',' | ';' /, count=1)", mem);
    assert(exactlyEqual(result, Value.list([Value.str("a"), Value.str("b;c")])));
    assert(evaluate("'a,b'.split(/ space* /, count=0)", mem).listValue.length == 1);
    foreach (source; ["'abc'.split(/ space* /)", "'abc'.split(',', count='1')"]) {
        bool rejected;
        try { evaluate(source, mem); }
        catch (YshError error) { rejected = error.status == 3; }
        assert(rejected, source);
    }
}
