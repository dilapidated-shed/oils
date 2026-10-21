module yshd.pretty;

import std.algorithm : max;
import std.array : replicate;
import std.conv : to;
import std.math : isFinite, isNaN;
import std.string : indexOf;
import std.utf : toUTF32;
import yshd.io_ysh : encodeBString, encodeJsonString, utf8ScalarLength;
import yshd.libc_text : wchar_t, wcswidth, winsize, ioctl, TIOCGWINSZ;
import yshd.value : Value, ValueKind, kindName, stringify;

/// display/pretty.py's measured document algebra. Suffix measures let groups
/// choose a layout without rescanning or guessing the enclosing value's width.
private struct Measure {
    size_t flat;
    ptrdiff_t nonflat = -1;
}

private Measure concatenate(Measure left, Measure right) {
    return Measure(left.flat + right.flat, left.nonflat != -1 ? left.nonflat :
        right.nonflat == -1 ? -1 : cast(ptrdiff_t)left.flat + right.nonflat);
}

private enum DocKind { text, lineBreak, concat, indent, group, ifFlat, flat }
private class Doc {
    DocKind kind;
    string text;
    size_t indentation;
    Doc[] children;
    Measure measure;
    this(DocKind kind) { this.kind = kind; }
}

private size_t displayWidth(string value) {
    try {
        auto wide = value.toUTF32();
        auto width = wcswidth(cast(const(wchar_t)*)wide.ptr, wide.length);
        if (width >= 0) return width;
    } catch (Exception error) {}
    return value.length;
}

private Doc text(string value) {
    auto result = new Doc(DocKind.text);
    result.text = value;
    result.measure = Measure(displayWidth(value), -1);
    return result;
}
private Doc lineBreak(string value) {
    auto result = text(value);
    result.kind = DocKind.lineBreak;
    result.measure.nonflat = 0;
    return result;
}
private Doc concat(Doc[] children) {
    auto result = new Doc(DocKind.concat);
    result.children = children;
    foreach (child; children) result.measure = concatenate(result.measure, child.measure);
    return result;
}
private Doc wrap(DocKind kind, Doc child, size_t indentation = 0) {
    auto result = new Doc(kind);
    result.children = [child];
    result.indentation = indentation;
    result.measure = child.measure;
    if (kind == DocKind.flat) result.measure.nonflat = -1;
    return result;
}
private Doc ifFlat(Doc flat, Doc nonflat) {
    auto result = new Doc(DocKind.ifFlat);
    result.children = [flat, nonflat];
    result.measure = Measure(flat.measure.flat, nonflat.measure.nonflat);
    return result;
}
private Doc joined(Doc[] items, string separator = ",", string spacing = " ") {
    Doc[] result;
    foreach (index, item; items) {
        if (index) result ~= [text(separator), lineBreak(spacing)];
        result ~= item;
    }
    return concat(result);
}
private Doc surrounded(string left, Doc child, string right) {
    return wrap(DocKind.group, concat([text(left),
        wrap(DocKind.indent, concat([lineBreak(""), child]), 4),
        lineBreak(""), text(right)]));
}
private Doc tabular(Doc[] items) {
    if (!items.length) return text("");
    size_t maximum;
    foreach (item; items) maximum = max(maximum, item.measure.flat);
    auto singleColumn = joined(items);
    if (maximum + 2 > 22) return singleColumn;
    Doc[] table;
    foreach (index, item; items) {
        table ~= wrap(DocKind.flat, item);
        if (index + 1 < items.length)
            table ~= [text(","), wrap(DocKind.group, lineBreak(" ".replicate(maximum - item.measure.flat + 1)))];
    }
    return wrap(DocKind.group, ifFlat(singleColumn, concat(table)));
}

private string render(Doc document, size_t width) {
    struct Fragment { Doc doc; size_t indent; bool flat; Measure suffix; }
    Fragment[] stack = [Fragment(wrap(DocKind.group, document), 0, false, Measure.init)];
    size_t column;
    string result;
    while (stack.length) {
        auto fragment = stack[$ - 1];
        --stack.length;
        auto doc = fragment.doc;
        final switch (doc.kind) {
        case DocKind.text:
            result ~= doc.text;
            column += doc.measure.flat;
            break;
        case DocKind.lineBreak:
            if (fragment.flat) { result ~= doc.text; column += doc.measure.flat; }
            else { result ~= "\n" ~ " ".replicate(fragment.indent); column = fragment.indent; }
            break;
        case DocKind.concat:
            auto suffix = fragment.suffix;
            foreach_reverse (child; doc.children) {
                stack ~= Fragment(child, fragment.indent, fragment.flat, suffix);
                suffix = concatenate(child.measure, suffix);
            }
            break;
        case DocKind.indent:
            stack ~= Fragment(doc.children[0], fragment.indent + doc.indentation, fragment.flat, fragment.suffix);
            break;
        case DocKind.group:
            auto measure = concatenate(Measure(doc.measure.flat, -1), fragment.suffix);
            auto remaining = measure.nonflat == -1 ? measure.flat : cast(size_t)measure.nonflat;
            stack ~= Fragment(doc.children[0], fragment.indent, column + remaining <= width, fragment.suffix);
            break;
        case DocKind.ifFlat:
            stack ~= Fragment(doc.children[fragment.flat ? 0 : 1], fragment.indent, fragment.flat, fragment.suffix);
            break;
        case DocKind.flat:
            stack ~= Fragment(doc.children[0], fragment.indent, true, fragment.suffix);
            break;
        }
    }
    return result;
}

/// YSH shell-style strings: single quotes where possible, byte escapes when
/// quotes, controls or invalid UTF-8 require the b'' representation.
private string yshString(string value) {
    bool raw = true;
    size_t offset;
    while (offset < value.length) {
        auto length = utf8ScalarLength(value, offset);
        auto byteValue = cast(ubyte)value[offset];
        if (!length || byteValue < 0x20 || byteValue == '\\' || byteValue == '\'') { raw = false; break; }
        offset += length;
    }
    if (raw) return "'" ~ value ~ "'";
    return encodeBString(value);
}

private bool identifier(string value) {
    foreach (index, char ch; value)
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                ch == '_' || (index && ch >= '0' && ch <= '9'))) return false;
    return value.length != 0;
}

private class ValueEncoder {
    bool[Object] visiting;
    Doc encode(Value value) {
        final switch (value.kind) {
        case ValueKind.nullValue: case ValueKind.boolean: case ValueKind.integer:
            return text(stringify(value));
        case ValueKind.floating:
            return text(isFinite(value.floatValue) ? stringify(value) : isNaN(value.floatValue)
                ? "NAN" : value.floatValue < 0 ? "-INFINITY" : "INFINITY");
        case ValueKind.stringValue: return text(yshString(value.stringValue));
        case ValueKind.list:
            Object identity = value.listValue;
            if (identity in visiting) return text("[...]");
            visiting[identity] = true;
            scope (exit) visiting.remove(identity);
            if (!value.listValue.length) return text("[]");
            Doc[] items;
            foreach (item; value.listValue.items) items ~= encode(item);
            return surrounded("[", tabular(items), "]");
        case ValueKind.dict:
            Object identity = value.dictValue;
            if (identity in visiting) return text("{...}");
            visiting[identity] = true;
            scope (exit) visiting.remove(identity);
            if (!value.dictValue.length) return text("{}");
            Doc[] items;
            foreach (key, item; value.dictValue)
                items ~= concat([text(identifier(key) ? key : yshString(key)), text(": "), encode(item)]);
            return surrounded("{", joined(items), "}");
        case ValueKind.rangeValue:
            auto upper = value.rangeUpper;
            return wrap(DocKind.group, concat([text("(Range"),
                wrap(DocKind.indent, concat([lineBreak(" "), joined([
                    text(to!string(value.rangeLower)), text("..<"), text(to!string(upper))], "", " ")]), 4),
                lineBreak(""), text(")")]));
        case ValueKind.sliceValue:
        case ValueKind.functionValue:
        case ValueKind.procValue:
        case ValueKind.placeValue:
        case ValueKind.eggexValue:
        case ValueKind.matchValue:
        case ValueKind.expressionValue:
        case ValueKind.commandValue:
        case ValueKind.builtinFunctionValue:
        case ValueKind.boundFunctionValue:
        case ValueKind.bashArrayValue:
        case ValueKind.bashAssocValue:
            // IDs and terminal styles await the rest of the value/display model.
            return text("<" ~ kindName(value) ~ ">");
        case ValueKind.objectValue:
            Object identity = value.objectValue;
            if (identity in visiting) return text("(...)");
            visiting[identity] = true;
            scope (exit) visiting.remove(identity);
            Doc[] properties;
            foreach (key, item; value.objectValue.properties)
                properties ~= concat([text(identifier(key) ? key : yshString(key)), text(": "), encode(item)]);
            auto own = surrounded("(", joined(properties), ")");
            return value.objectValue.prototype is null ? own
                : concat([own, text(" --> "), encode(Value.object(value.objectValue.prototype))]);
        }
    }
}

string prettyValue(Value value, size_t width = 80) {
    auto doc = (new ValueEncoder()).encode(value);
    if (value.kind <= ValueKind.dict || value.kind == ValueKind.objectValue) {
        auto name = kindName(value);
        doc = concat([text("(" ~ name ~ ")"), lineBreak(" ".replicate(6 - name.length)), doc]);
    }
    return render(doc, width);
}

/// ASDL diagnostics retain their field names, separately from YSH value
/// notation. Share measured layout with ordinary printing.
private Doc asdlRecord(string name, Doc[] fields) {
    if (!fields.length) return text("(" ~ name ~ ")");
    return wrap(DocKind.group, concat([text("(" ~ name),
        wrap(DocKind.indent, concat([lineBreak(" "), joined(fields, "", " ")]), 4),
        lineBreak(""), text(")")]));
}

private class AsdlEncoder {
    bool[Object] active;
    private Doc leaf(string value) {
        bool plain = value.length != 0;
        foreach (ch; value) if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                (ch >= '0' && ch <= '9') || ch == '_' || ch == '.' || ch == '/' || ch == '-')) plain = false;
        return text(plain ? value : encodeJsonString(value));
    }
    private Doc record(string name, Doc[] fields) {
        return asdlRecord(name, fields);
    }
    Doc encode(Value value) {
        switch (value.kind) {
        case ValueKind.nullValue: return text("(value.Null)");
        case ValueKind.boolean: return record("value.Bool", [text(value.booleanValue ? "b:T" : "b:F")]);
        case ValueKind.integer: return record("value.Int", [text("i:" ~ stringify(value))]);
        case ValueKind.floating: return record("value.Float", [text("f:" ~ stringify(value))]);
        case ValueKind.stringValue: return record("value.Str", [concat([text("s:"), leaf(value.stringValue)])]);
        case ValueKind.list:
            Object identity = value.listValue;
            if (identity in active) return text("...");
            active[identity] = true;
            scope (exit) active.remove(identity);
            Doc[] items;
            foreach (item; value.listValue.items) items ~= encode(item);
            return record("value.List", [concat([text("items:"), surrounded("[", joined(items, "", " "), "]")])]);
        case ValueKind.dict:
            Object identity = value.dictValue;
            if (identity in active) return text("...");
            active[identity] = true;
            scope (exit) active.remove(identity);
            Doc[] items;
            foreach (key, item; value.dictValue) items ~= [leaf(key), encode(item)];
            return record("value.Dict", [concat([text("d:"), surrounded("{", joined(items, "", " "), "}")])]);
        case ValueKind.rangeValue:
            return record("value.Range", [text("lower:" ~ to!string(value.rangeLower)), text("upper:" ~ to!string(value.rangeUpper))]);
        default:
            import yshd.value : YshError;
            throw new YshError("ASDL diagnostics for " ~ kindName(value) ~ " are not translated");
        }
    }
}

string asdlValue(Value value, size_t width = 80) {
    return render((new AsdlEncoder()).encode(value), width);
}

string prettyCell(string name, Value value, bool readOnly, size_t width = 80) {
    auto doc = asdlRecord("Cell", [text("exported:F"), text("readonly:" ~ (readOnly ? "T" : "F")),
        text("nameref:F"), concat([text("val:"), (new AsdlEncoder()).encode(value)])]);
    // Pp writes the name before invoking the ASDL printer, whose column starts
    // at zero. It therefore does not subtract the prefix from max_width.
    return name ~ " = " ~ render(doc, width);
}

size_t terminalWidth(int descriptor) {
    winsize size;
    if (ioctl(descriptor, TIOCGWINSZ, &size) == 0 && size.ws_col > 0) return size.ws_col;
    return 80;
}
