module yshd.read_builtin;

// The common OSH/YSH read implementation.  Keep the input descriptor owned
// by Memory: these reads must not close it or consume a following command's
// bytes through stdio lookahead.
import std.conv : to;
import std.string : startsWith;
import yshd.expr : ParsedArguments;
import yshd.io_stream : readRawLine, readInputBytes, readInputFd, readDelimitedFd, StreamReadError;
import yshd.split : IfsSplitter;
import yshd.state : Memory, FramePlace;
import yshd.value : Value, ValueKind, YshDict, UsageError, YshError, YshTypeError;

private Value readLines(string bytes, bool withEol) {
    Value[] lines;
    size_t begin;
    for (size_t index = 0; index < bytes.length; ++index) {
        auto character = bytes[index];
        if (character != '\n') continue;
        lines ~= Value.str(bytes[begin .. index + (withEol ? 1 : 0)]);
        begin = index + 1;
    }
    if (begin < bytes.length) lines ~= Value.str(bytes[begin .. $]);
    return Value.list(lines);
}

void runReadBuiltin(string[] words, ParsedArguments parsed, bool hasBlock, Memory mem) {
    bool all, line, rawLine, allLines, withEol;
    bool raw, nulDelimited, hasDelimiter, optionsDone;
    string delimiter;
    string arrayName;
    long byteCount = -1, maxCharacters = -1, exactCount = -1;
    int inputFd = mem.inputFile.fileno();
    string[] names;

    for (size_t index; index < words.length; ++index) {
        auto word = words[index];
        if (!optionsDone && word == "--") { optionsDone = true; continue; }
        if (!optionsDone && word == "--all") { all = true; continue; }
        if (!optionsDone && word == "--line") { line = true; continue; }
        if (!optionsDone && word == "--raw-line") { rawLine = true; continue; }
        if (!optionsDone && word == "--all-lines") { allLines = true; continue; }
        if (!optionsDone && word == "--with-eol") { withEol = true; continue; }
        if (!optionsDone && (word == "--num-bytes" || word.startsWith("--num-bytes="))) {
            string number;
            if (word == "--num-bytes") {
                if (++index == words.length) throw new UsageError("read --num-bytes expects an integer");
                number = words[index];
            } else number = word["--num-bytes=".length .. $];
            try { byteCount = to!long(number); }
            catch (Exception error) { throw new UsageError("read --num-bytes expects an integer"); }
            continue;
        }
        if (!optionsDone && word.length > 1 && word[0] == '-') {
            if (word.startsWith("--")) throw new UsageError("read: unexpected flag");
            for (size_t offset = 1; offset < word.length; ++offset) {
                switch (word[offset]) {
                case 'r': raw = true; break;
                case '0': nulDelimited = true; raw = true; break;
                case 'n':
                case 'N':
                case 'u':
                    char flag = word[offset];
                    string number;
                    if (offset + 1 < word.length) number = word[offset + 1 .. $];
                    else {
                        if (++index == words.length)
                            throw new UsageError("read -" ~ flag ~ " expects a non-negative integer");
                        number = words[index];
                    }
                    long count;
                    try { count = to!long(number); }
                    catch (Exception error) {
                        throw new UsageError("read -" ~ flag ~ " expects a non-negative integer");
                    }
                    if (count < 0 || flag == 'u' && count > int.max)
                        throw new UsageError("read -" ~ flag ~ " expects a non-negative integer");
                    if (flag == 'n') maxCharacters = count;
                    else if (flag == 'N') exactCount = count;
                    else inputFd = cast(int)count;
                    offset = word.length;
                    break;
                case 'a':
                    if (offset + 1 < word.length) arrayName = word[offset + 1 .. $];
                    else {
                        if (++index == words.length)
                            throw new UsageError("read -a expects an array name");
                        arrayName = words[index];
                    }
                    if (!arrayName.length) throw new UsageError("read -a expects an array name");
                    offset = word.length;
                    break;
                case 'd':
                    if (offset + 1 < word.length) delimiter = word[offset + 1 .. $];
                    else {
                        if (++index == words.length) throw new UsageError("read -d expects a delimiter");
                        delimiter = words[index];
                    }
                    hasDelimiter = true;
                    offset = word.length;
                    break;
                default:
                    throw new UsageError("read: unexpected flag");
                }
            }
            continue;
        }
        optionsDone = true;
        names ~= word;
    }

    if (all && line) throw new YshError("read accepts only one of --all and --line");
    bool yshMode = all || line || rawLine || allLines || byteCount != -1;
    if (hasBlock) throw new UsageError("read does not accept a block");

    if (yshMode) {
        Value place = Value.place(new FramePlace(mem.currentFrame, "_reply"));
        if (parsed !is null) {
            auto args = parsed.eval(mem);
            if (args.positional.length != 1 || args.named.length || args.hasBlock ||
                    args.positional[0].kind != ValueKind.placeValue)
                throw new YshTypeError("read expects one Place argument");
            place = args.positional[0];
        }
        // --all-lines is a D continuation: the retained reference's READ_SPEC
        // has no such flag.  The proposed :name syntax is deliberately scoped
        // to this mode, not generalized to the existing read --all contract.
        if (allLines && names.length == 1 && names[0].length > 1 &&
                names[0][0] == ':' && parsed is null)
            place = Value.place(new FramePlace(mem.currentFrame, names[0][1 .. $]));
        else if (names.length)
            throw new UsageError("read: got extra argument");

        string result;
        bool endOfInput;
        try {
            if (byteCount != -1) result = readInputBytes(mem.inputFile, byteCount < 0 ? 0 : byteCount);
            else if (rawLine) result = readRawLine(mem.inputFile, endOfInput, withEol);
            else if (all || allLines) result = readInputBytes(mem.inputFile);
            else {
                // Preserve the retained --line implementation while the full
                // buffered/unbuffered read interface is translated.
                result = mem.inputFile.readln();
                endOfInput = !result.length;
                if (result.length && result[$ - 1] == '\n') {
                    result = result[0 .. $ - 1];
                    if (result.length && result[$ - 1] == '\r')
                        result = result[0 .. $ - 1];
                }
            }
        } catch (StreamReadError error) {
            mem.errorFile.writeln("read: ", error.msg);
            mem.lastStatus = 1;
            return;
        }
        place.placeValue.assign(allLines ? readLines(result, withEol) : Value.str(result));
        mem.lastStatus = endOfInput && !all && !allLines ? 1 : 0;
        return;
    }

    // OSH read rejects a typed Place without a YSH input mode.
    if (parsed !is null) throw new UsageError("read needs --all, --raw-line, or --num-bytes for typed args");

    // builtin/read_osh.py:_Read: -N consumes exact raw bytes regardless of
    // -d and -n, writes the first name, and clears additional destinations.
    if (exactCount >= 0) {
        string contents;
        try { contents = readInputFd(inputFd, exactCount); }
        catch (StreamReadError error) {
            mem.errorFile.writeln("read: ", error.msg);
            mem.lastStatus = 1;
            return;
        }
        if (!names.length) names ~= "REPLY";
        mem.setShellVar(names[0], Value.str(contents));
        foreach (name; names[1 .. $]) mem.setShellVar(name, Value.str(""));
        mem.lastStatus = contents.length == cast(size_t)exactCount ? 0 : 1;
        return;
    }

    ubyte endByte = nulDelimited ? 0 : hasDelimiter
        ? cast(ubyte)(delimiter.length ? delimiter[0] : 0) : cast(ubyte)'\n';
    bool eof;
    string contents;
    try {
        contents = readDelimitedFd(inputFd, endByte, eof, !raw, maxCharacters);
    } catch (StreamReadError error) {
        mem.errorFile.writeln("read: ", error.msg);
        mem.lastStatus = 1;
        return;
    }
    bool splitting = !nulDelimited && (names.length != 0 || arrayName.length != 0);
    if (!names.length) names ~= "REPLY";
    auto splitter = new IfsSplitter(splitting ? mem.wordVariable("IFS") : "");
    splitter.allowEscape = !raw;
    splitter.maximumSplit = arrayName.length ? -1 : cast(long)names.length - 1;
    splitter.pushFragment(contents);
    auto parts = splitter.finish();
    if (arrayName.length) {
        // -a replaces the existing BashArray, including on empty input.
        auto array = new YshDict();
        foreach (index, item; parts) array.set(to!string(index), Value.str(item));
        mem.setShellVar(arrayName, Value.shellArray(array));
    } else foreach (index, name; names) {
        // An empty input still sets the destination (including at EOF).
        mem.setShellVar(name, Value.str(index < parts.length ? parts[index] : ""));
    }
    mem.lastStatus = eof ? 1 : 0;
}
