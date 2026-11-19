module yshd.help;

import std.stdio : File;
import std.string : indexOf;
import core.sys.posix.unistd : isatty;

import yshd.help_resources : ResourceLoader, ResourceError;
import yshd.state : Memory;
import yshd.value : InterpreterFailure, UsageError;

// The strings and extra blank line are core/util.py:PrintTopicHeader's
// public output, including the full display/ansi.py RESET sequence.
void printTopicHeader(string topic, File output) {
    if (isatty(output.fileno())) output.write("\x1b[7m " ~ topic ~ " \x1b[0;0m\n");
    else output.write("~~~ " ~ topic ~ " ~~~\n");
    output.write("\n");
}

bool printEmbeddedHelp(ResourceLoader loader, string topic, lazy File output) {
    string contents;
    try { contents = loader.get("_devbuild/help/" ~ topic); }
    catch (ResourceError error) { return false; }
    printTopicHeader(topic, output);
    output.write(contents);
    output.write("\n");
    return true;
}

private string resourceVersion(ResourceLoader loader) {
    auto contents = loader.get("oils-version.txt");
    auto end = contents.indexOf('\n');
    return end < 0 ? contents : contents[0 .. end];
}

/// core/util.py:HelpFlag prints the applet usage and shared shell flags.
void printHelpFlag(ResourceLoader loader, string topic, File output) {
    output.write("Oils " ~ resourceVersion(loader) ~ "\t\thttps://oils.pub/\n\n");
    if (!printEmbeddedHelp(loader, topic, output))
        throw new InterpreterFailure("Missing embedded help topic " ~ topic);
    if (!printEmbeddedHelp(loader, "shell-flags", output))
        throw new InterpreterFailure("Missing embedded help topic shell-flags");
}

// Python 2 repr(str) is byte-oriented; in particular, a non-ASCII topic
// cannot appear literally in the missing-topic diagnostic.
private string topicRepr(string topic) {
    auto quote = topic.indexOf('\'') >= 0 && topic.indexOf('"') < 0 ? '"' : '\'';
    string result = [quote];
    foreach (character; topic) {
        if (character == quote || character == '\\') result ~= "\\" ~ character;
        else if (character == '\t') result ~= "\\t";
        else if (character == '\n') result ~= "\\n";
        else if (character == '\r') result ~= "\\r";
        else if (character < ' ' || character >= 0x7f) {
            result ~= "\\x";
            result ~= "0123456789abcdef"[cast(ubyte)character >> 4];
            result ~= "0123456789abcdef"[character & 15];
        } else result ~= character;
    }
    return result ~ quote;
}

private string asciiLower(string text) {
    char[] result = text.dup;
    foreach (ref character; result)
        if (character >= 'A' && character <= 'Z') character += 'a' - 'A';
    return cast(string)result;
}

/// builtin/misc_osh.py:Help retains the applet language, loader, metadata,
/// and version at construction. Changing option groups or $0 cannot change
/// the selected chapter index, and later file edits cannot change URLs.
class HelpBuiltin {
    private string language;
    private ResourceLoader loader;
    private const(string[string]) metadata;
    private string versionString;

    this(string language, ResourceLoader loader, const(string[string]) metadata = null) {
        this.language = language;
        this.loader = loader;
        this.metadata = metadata;
        versionString = resourceVersion(loader);
    }

    private int showTopic(string topic, Memory mem) {
        enum prefix = "https://oils.pub/release/";
        auto chapter = topic in metadata;
        // A null generated value denotes an embedded card, and is distinct
        // from the empty (but non-null) chapter name.
        if (chapter !is null && (*chapter).ptr !is null) {
            printTopicHeader(topic, mem.outputFile);
            mem.outputFile.write("    " ~ prefix ~ versionString ~ "/doc/ref/chap-" ~ *chapter ~ ".html#" ~ topic ~ "\n\n");
            return 0;
        }
        auto lower = asciiLower(topic);
        if (lower.length >= 8 && lower[0 .. 8] == "oils-err") {
            mem.outputFile.write("\n    " ~ prefix ~ versionString ~ "/doc/error-catalog.html#" ~ lower ~ "\n\n");
            return 0;
        }
        if (printEmbeddedHelp(loader, topic, mem.outputFile)) return 0;
        mem.writeDiagnostic("no help topics match " ~ topicRepr(topic));
        return 1;
    }

    int run(string[] words, Memory mem) {
        size_t index;
        for (; index < words.length; ++index) {
            auto word = words[index];
            if (word == "--") { ++index; break; }
            if (word.length < 2 || word[0] != '-') break;
            // HELP_SPEC has no accepted flags. args.Parse remaps -0 to -Z.
            auto flag = word[1] == '0' ? 'Z' : word[1];
            throw new UsageError("doesn't accept flag -" ~ flag);
        }
        if (index < words.length) return showTopic(words[index], mem);

        if (showTopic("help", mem) != 0)
            throw new InterpreterFailure("Missing embedded help topic help");
        auto chapters = language ~ "-chapters";
        if (showTopic(chapters, mem) != 0)
            throw new InterpreterFailure("Missing embedded help topic " ~ chapters);
        mem.outputFile.write("All docs: https://oils.pub/release/" ~ versionString ~ "/doc/\n\n");
        return 0;
    }
}
