module help_data_gen;

import std.algorithm : sort;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, read, write;
import std.path : baseName;
import std.stdio : stderr;

// Convert the original doctools/help_gen.py outputs to D data. This program
// deliberately does not render Markdown or execute/import Python source.
private class MetadataParser {
    private string text;
    private size_t position;

    this(string text) { this.text = text; }

    private void space() {
        while (position < text.length &&
                (text[position] == ' ' || text[position] == '\n' ||
                 text[position] == '\r' || text[position] == '\t')) ++position;
    }

    private void expect(string token) {
        space();
        if (position + token.length > text.length ||
                text[position .. position + token.length] != token)
            throw new Exception("Expected " ~ token ~ " at byte " ~ to!string(position));
        position += token.length;
    }

    private int digit(char value, uint radix) {
        int result = value >= '0' && value <= '9' ? value - '0' :
            value >= 'a' && value <= 'f' ? value - 'a' + 10 :
            value >= 'A' && value <= 'F' ? value - 'A' + 10 : -1;
        if (result < 0 || result >= radix) throw new Exception("Invalid Python string escape");
        return result;
    }

    private string stringLiteral() {
        space();
        if (position == text.length || (text[position] != '\'' && text[position] != '"'))
            throw new Exception("Expected Python byte string at byte " ~ to!string(position));
        auto quote = text[position++];
        string result;
        while (position < text.length) {
            auto value = text[position++];
            if (value == quote) return result.length ? result : "";
            if (value != '\\') { result ~= value; continue; }
            if (position == text.length) break;
            auto escape = text[position++];
            switch (escape) {
                case '\\': case '\'': case '"': result ~= escape; break;
                case 'n': result ~= '\n'; break;
                case 'r': result ~= '\r'; break;
                case 't': result ~= '\t'; break;
                case 'a': result ~= '\a'; break;
                case 'b': result ~= '\b'; break;
                case 'f': result ~= '\f'; break;
                case 'v': result ~= '\v'; break;
                case 'x':
                    if (position + 2 > text.length) throw new Exception("Short Python hex escape");
                    auto byteValue = digit(text[position], 16) * 16 + digit(text[position + 1], 16);
                    position += 2;
                    result ~= cast(char)byteValue;
                    break;
                default:
                    if (escape < '0' || escape > '7') throw new Exception("Unexpected Python string escape");
                    uint byteValue = escape - '0';
                    for (size_t count = 1; count < 3 && position < text.length &&
                            text[position] >= '0' && text[position] <= '7'; ++count)
                        byteValue = byteValue * 8 + text[position++] - '0';
                    if (byteValue > 255) throw new Exception("Python octal escape is not a byte");
                    result ~= cast(char)byteValue;
            }
        }
        throw new Exception("Unterminated Python string");
    }

    string[string] parse() {
        expect("TOPICS"); expect("="); expect("{");
        string[string] result;
        while (true) {
            space();
            if (position < text.length && text[position] == '}') { ++position; return result; }
            auto key = stringLiteral();
            expect(":");
            space();
            string value;
            if (position < text.length && (text[position] == '\'' || text[position] == '"'))
                value = stringLiteral();
            else expect("None");
            if (key in result) throw new Exception("Duplicate help topic: " ~ key);
            result[key] = value;
            space();
            if (position < text.length && text[position] == '}') continue;
            expect(",");
        }
    }
}

private string literal(string bytes) {
    string result = "\"";
    foreach (ubyte value; cast(const(ubyte)[])bytes) {
        if (value == '"' || value == '\\') result ~= "\\" ~ cast(char)value;
        else if (value == '\n') result ~= "\\n";
        else if (value == '\r') result ~= "\\r";
        else if (value == '\t') result ~= "\\t";
        else if (value < 32 || value >= 127)
            result ~= "\\x" ~ "0123456789abcdef"[value >> 4] ~ "0123456789abcdef"[value & 15];
        else result ~= cast(char)value;
    }
    return result ~ "\"";
}

private string digest(string bytes) {
    string result;
    foreach (value; sha256Of(bytes)) {
        result ~= "0123456789abcdef"[value >> 4];
        result ~= "0123456789abcdef"[value & 15];
    }
    return result;
}

int main(string[] arguments) {
    if (arguments.length != 5) {
        stderr.writeln("Usage: help_data_gen HELP_META_PY HELP_DIRECTORY VERSION_FILE OUTPUT_D");
        return 2;
    }
    auto metadataBytes = cast(string)read(arguments[1]);
    auto metadata = new MetadataParser(metadataBytes).parse();
    auto versionBytes = cast(string)read(arguments[3]);
    string[] paths;
    foreach (entry; dirEntries(arguments[2], SpanMode.shallow)) {
        if (!entry.isFile) throw new Exception("Non-file in generated help directory: " ~ entry.name);
        paths ~= entry.name;
    }
    paths.sort();
    if (!paths.length || !metadata.length)
        throw new Exception("Canonical help generation must contain resources and topic metadata");
    auto topics = metadata.keys;
    topics.sort();
    string output = "// Generated by ysh/d/tools/help_data_gen.d from original doctools/help_gen.py outputs.\n" ~
        "// Regenerate with canonical help_meta.py, help directory and oils-version.txt; do not edit.\n" ~
        "module yshd.help_data;\n\n" ~
        "enum helpMetadataSha256 = " ~ literal(digest(metadataBytes)) ~ ";\n" ~
        "enum helpVersionSha256 = " ~ literal(digest(versionBytes)) ~ ";\n" ~
        "enum sourceVersionBytes = " ~ literal(versionBytes) ~ ";\n\n" ~
        "enum helpMetadataEntries = " ~ to!string(metadata.length) ~ ";\n" ~
        "enum helpResourceCount = " ~ to!string(paths.length) ~ ";\n\n" ~
        "// null values mark embedded topics; an empty string is a non-null chapter.\n" ~
        "private __gshared const(string[string]) topicMetadata;\n" ~
        "shared static this() {\n    topicMetadata = [\n";
    foreach (topic; topics)
        output ~= "        " ~ literal(topic) ~ ": " ~
            (metadata[topic].ptr is null ? "null" : literal(metadata[topic])) ~ ",\n";
    output ~= "    ];\n}\n\n" ~
        "const(string[string]) canonicalTopicMetadata() { return topicMetadata; }\n\n" ~
        "const(string[string]) minimalTopicMetadata() { return null; }\n\n" ~
        "struct HelpResource { string path; string contents; string sha256; }\n" ~
        "immutable HelpResource[] canonicalHelpResources = [\n";
    foreach (path; paths) {
        auto contents = cast(string)read(path);
        output ~= "    HelpResource(" ~ literal("_devbuild/help/" ~ baseName(path)) ~
            ", " ~ literal(contents) ~ ", " ~ literal(digest(contents)) ~ "),\n";
    }
    output ~= "];\n";
    write(arguments[4], output);
    return 0;
}

unittest {
    auto metadata = new MetadataParser("TOPICS = {'embedded': None, 'url': 'chapter', 'empty': '', 'bytes': '\\xff\\n'}\n").parse();
    assert(metadata["embedded"].ptr is null);
    assert(metadata["empty"].ptr !is null && metadata["empty"].length == 0);
    assert(metadata["bytes"] == "\xff\n");
    assert(literal("a\"\\\n\x00\xff") == "\"a\\\"\\\\\\n\\x00\\xff\"");
    assert(digest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}
