module yshd.printf_osh;

import yshd.state : Memory;
import yshd.value : Value, ValueKind, UsageError, YshError;
import yshd.io_ysh : EchoEscapeResult, decodeEchoEscapes;
import std.string : indexOf, toStringz, stripLeft;
import std.conv : to;
import std.array : replicate;

private struct Part {
    string literal, flags, width, precision, timeFormat;
    char type = '\0';
}

private EchoEscapeResult escapes(string text, bool argument) {
    // Printf's format accepts three octal digits; %b additionally accepts
    // the echo-style optional leading zero. Decode only after finding %
    // fields, so an escaped percent never becomes a conversion directive.
    string normalized;
    for (size_t i; i < text.length;) {
        if (text[i] == '\\' && i + 1 < text.length) {
            auto next = text[i + 1];
            if (next >= '0' && next <= '7') {
                auto start = i + 1;
                auto end = start;
                auto limit = argument && next == '0' ? 4 : 3;
                while (end < text.length && end - start < limit && text[end] >= '0' && text[end] <= '7') ++end;
                normalized ~= "\\0" ~ text[start + (argument && next == '0' ? 1 : 0) .. end];
                i = end;
            } else {
                // Backslash-c only terminates %b, not the format language.
                if (!argument && next == 'c') normalized ~= "\\\\c";
                else normalized ~= text[i .. i + 2];
                i += 2;
            }
        } else normalized ~= text[i++];
    }
    return decodeEchoEscapes(normalized);
}

private Part[] parseFormat(string source) {
    Part[] parts;
    size_t index;
    while (index < source.length && source[index] != '\0') {
        if (source[index] != '%') {
            auto start = index;
            while (index < source.length && source[index] != '%' && source[index] != '\0') {
                if (source[index] == '\\' && index + 1 < source.length) index += 2;
                else ++index;
            }
            parts ~= Part(escapes(source[start .. index], false).text);
            continue;
        }
        ++index;
        if (index < source.length && source[index] == '%') { ++index; parts ~= Part("%"); continue; }
        Part part;
        while (index < source.length && "-0 +#".indexOf(source[index]) >= 0) {
            if (" +#".indexOf(source[index]) >= 0) throw new UsageError("printf: unsupported format flag");
            part.flags ~= source[index++];
        }
        string number() {
            auto start = index;
            if (index < source.length && source[index] == '*') ++index;
            else while (index < source.length && source[index] >= '0' && source[index] <= '9') ++index;
            return source[start .. index];
        }
        part.width = number();
        if (index < source.length && source[index] == '.') {
            ++index; part.precision = number();
            if (!part.precision.length) part.precision = "0";
        }
        if (index == source.length) throw new UsageError("printf: expected a format character");
        part.type = source[index++];
        if (part.type == '(') {
            auto start = index;
            while (index < source.length && source[index] != ')') ++index;
            part.timeFormat = source[start .. index];
            if (index + 1 >= source.length || source[index + 1] != 'T') throw new UsageError("printf: invalid time format");
            index += 2; part.type = 'T';
        } else if ("disqbcouxX".indexOf(part.type) < 0) throw new UsageError("printf: unsupported format character");
        parts ~= part;
    }
    return parts;
}

private long integer(string text) {
    import core.stdc.stdlib : strtoll;
    import core.stdc.errno : errno, ERANGE;
    text = text.stripLeft();
    if (text.length && (text[0] == '\'' || text[0] == '"')) {
        if (text.length == 1) return 0;
        if (text.length == 2) return cast(ubyte)text[1];
        import std.utf : decode, UTFException;
        size_t start = 1;
        try { return decode(text, start); }
        catch (UTFException error) { return cast(ubyte)text[1]; }
    }
    if (!text.length) throw new YshError("printf: expected an integer", 1);
    immutable(char)* end;
    auto input = text.toStringz();
    errno = 0;
    auto value = strtoll(input, &end, 0);
    if (errno == ERANGE || end != input + text.length) throw new YshError("printf: expected an integer", 1);
    return value;
}

int runPrintf(string[] words, Memory mem) {
    size_t index;
    string destination;
    if (words.length && words[0] == "-v") {
        if (words.length < 2) throw new UsageError("printf -v requires a variable");
        destination = words[1]; index = 2;
    }
    if (index < words.length && words[index] == "--") ++index;
    else if (index < words.length && words[index].length > 1 && words[index][0] == '-')
        throw new UsageError("printf: invalid flag");
    if (index == words.length) throw new UsageError("printf requires a format string");
    auto parts = parseFormat(words[index++]);
    auto arguments = words[index .. $];
    size_t argumentIndex;
    string output;
    bool stop;
    string next() { return argumentIndex < arguments.length ? arguments[argumentIndex++] : ""; }
    long size(string specification) {
        if (!specification.length) return -1;
        auto text = specification == "*" ? next() : specification;
        try { return to!long(text); }
        catch (Exception error) { throw new YshError("printf: invalid width or precision", 1); }
    }
    try {
        do {
            auto previous = argumentIndex;
            foreach (part; parts) {
                if (!part.type) { output ~= part.literal; continue; }
                auto width = size(part.width), precision = size(part.precision);
                auto hasArgument = argumentIndex < arguments.length;
                auto text = next();
                switch (part.type) {
                case 's': if (precision >= 0 && precision < text.length) text = text[0 .. cast(size_t)precision]; break;
                case 'b': auto decoded = escapes(text, true); text = decoded.text; stop = decoded.stop; break;
                case 'q':
                    bool bare = text.length != 0;
                    foreach (ch; text) if (!(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' ||
                            ch >= '0' && ch <= '9' || "_-/.:".indexOf(ch) >= 0)) bare = false;
                    if (!bare) { import yshd.traps : shellQuote; text = shellQuote(text); }
                    break;
                case 'c': text = text.length ? text[0 .. 1] : "\0"; break;
                default:
                    auto number = part.type == 'T' && !hasArgument ? -1 : integer(text);
                    if (part.type == 'T') {
                        import core.sys.posix.stdlib : setenv;
                        import core.sys.posix.time : tzset;
                        if (auto timezone = mem.getCell("TZ"))
                            if (timezone.exported && timezone.value.kind == ValueKind.stringValue)
                                setenv("TZ", timezone.value.stringValue.toStringz(), 1);
                        tzset();
                        import core.stdc.time : time, time_t, localtime, strftime;
                        time_t seconds = number == -1 ? time(null) : number == -2 ? cast(time_t)mem.shellStartTime : cast(time_t)number;
                        auto local = localtime(&seconds);
                        if (local is null) throw new YshError("printf: invalid time", 1);
                        char[] buffer = new char[128];
                        size_t length;
                        if (part.timeFormat.length) {
                            while (true) {
                                length = strftime(buffer.ptr, buffer.length, part.timeFormat.toStringz(), local);
                                if (length) break;
                                if (buffer.length >= 1 << 20) throw new YshError("printf: time format too large", 1);
                                buffer.length *= 2;
                            }
                        }
                        text = buffer[0 .. length].idup;
                        if (precision >= 0 && precision < text.length) text = text[0 .. cast(size_t)precision];
                        break;
                    }
                    if (number < 0 && "ouxX".indexOf(part.type) >= 0) throw new YshError("printf: negative unsigned number", 1);
                    if (part.type == 'o') { import std.format : format; text = format("%o", number); }
                    else if (part.type == 'x') { import std.format : format; text = format("%x", number); }
                    else if (part.type == 'X') { import std.format : format; text = format("%X", number); }
                    else text = to!string(number);
                    auto zeroWidth = part.flags.indexOf('0') >= 0 && width >= 0 ? width : precision;
                    if (zeroWidth > 1 << 24) throw new YshError("printf: padding too large", 1);
                    auto sign = text[0] == '-' ? "-" : "";
                    auto digits = text[sign.length .. $];
                    if (part.flags.indexOf('0') >= 0 && width >= 0) zeroWidth -= sign.length;
                    if (zeroWidth >= 0 && cast(ulong)zeroWidth > digits.length)
                        text = sign ~ "0".replicate(cast(size_t)zeroWidth - digits.length) ~ digits;
                    break;
                }
                if (width > 1 << 24) throw new YshError("printf: padding too large", 1);
                if (width >= 0 && cast(ulong)width > text.length) {
                    auto padding = " ".replicate(cast(size_t)width - text.length);
                    text = part.flags.indexOf('-') >= 0 ? text ~ padding : padding ~ text;
                }
                output ~= text;
                if (stop) break;
            }
            if (stop || previous == argumentIndex) break;
        } while (argumentIndex < arguments.length);
    } catch (YshError error) {
        mem.errorFile.writeln(error.msg); return error.status;
    }
    if (destination.length) {
        // The retained shell arithmetic place parser also owns indexed -v.
        import yshd.arith : assignShellString;
        try { assignShellString(destination, output, mem); }
        catch (YshError error) { mem.errorFile.writeln(error.msg); return error.status; }
    } else mem.outputFile.write(output);
    return 0;
}
