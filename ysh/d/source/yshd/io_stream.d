module yshd.io_stream;

import std.stdio : File;
import std.conv : to;
import core.stdc.errno : errno, EINTR;
import core.stdc.string : strerror;
import core.sys.posix.unistd : read;

class StreamReadError : Exception {
    this(int error) { super(to!string(strerror(error))); }
}

/// builtin/read_osh.py:ReadLineSlowly must leave following bytes on the
/// descriptor for a subsequent external command. Stdio read-ahead cannot do
/// that. Preserve arbitrary bytes and remove only the newline delimiter.
string readRawLine(File input, out bool endOfInput, bool withEol = false) {
    string result;
    char character;
    while (true) {
        auto count = read(input.fileno(), &character, 1);
        if (count < 0) {
            if (errno == EINTR) continue; // pending trap execution is separate
            throw new StreamReadError(errno);
        }
        if (!count) { endOfInput = result.length == 0; break; }
        if (character == '\n') { if (withEol) result ~= character; break; }
        result ~= character;
    }
    return result;
}

/// ReadAll / _ReadN use the same descriptor boundary and retry EINTR.
string readInputBytes(File input, long count = -1) {
    string result;
    char[4096] buffer;
    while (count != 0) {
        auto size = count < 0 || count > buffer.length ? buffer.length : cast(size_t)count;
        auto received = read(input.fileno(), buffer.ptr, size);
        if (received < 0) {
            if (errno == EINTR) continue;
            throw new StreamReadError(errno);
        }
        if (!received) break;
        result ~= buffer[0 .. cast(size_t)received];
        if (count > 0) count -= received;
    }
    return result;
}

unittest {
    auto input = File.tmpfile();
    input.write("first\r\nlast\0byte");
    input.rewind();
    bool end;
    assert(readRawLine(input, end) == "first\r" && !end);
    // A descriptor reader must still see the first following byte: this
    // catches accidental stdio read-ahead in readRawLine.
    assert(readInputBytes(input, 1) == "l");
    assert(readRawLine(input, end) == "ast\0byte" && !end);
    assert(readRawLine(input, end) == "" && end);
    input.rewind();
    assert(readInputBytes(input, 3) == "fir");
    assert(readInputBytes(input) == "st\r\nlast\0byte");
}
