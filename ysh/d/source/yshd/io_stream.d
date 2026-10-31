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
    return readInputFd(input.fileno(), count);
}

/// The caller owns fd; never make an intermediate stdio stream that can close it.
string readInputFd(int fd, long count = -1) {
    string result;
    char[4096] buffer;
    while (count != 0) {
        auto size = count < 0 || count > buffer.length ? buffer.length : cast(size_t)count;
        auto received = read(fd, buffer.ptr, size);
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


/// Read the OSH read builtin's delimiter without buffering past the byte.
/// An EOF is reported even when a partial value was obtained, unlike
/// readRawLine's EOF convention for YSH's --raw-line.
string readDelimited(File input, ubyte delimiter, out bool eof,
        bool allowEscape = false, long maxCharacters = -1) {
    return readDelimitedFd(input.fileno(), delimiter, eof, allowEscape, maxCharacters);
}

/// Direct OSH descriptor reads preserve -u ownership and delimiter boundaries.
string readDelimitedFd(int fd, ubyte delimiter, out bool eof,
        bool allowEscape = false, long maxCharacters = -1) {
    eof = false;
    string result;
    bool escaped;
    long charactersRead;
    char character;
    while (maxCharacters < 0 || charactersRead < maxCharacters) {
        auto count = read(fd, &character, 1);
        if (count < 0) {
            if (errno == EINTR) continue;
            throw new StreamReadError(errno);
        }
        if (!count) { eof = true; break; }
        if (escaped) {
            escaped = false;
            // OSH read without -r discards a backslash-newline pair.
            if (character == '\n') continue;
            result ~= '\\';
            result ~= character;
        } else if (allowEscape && character == '\\') {
            escaped = true;
        } else if (cast(ubyte)character == delimiter) {
            break;
        } else if (character != '\0') {
            // The original _ReadPortion ignores NUL except as a delimiter.
            result ~= character;
        }
        ++charactersRead;
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
