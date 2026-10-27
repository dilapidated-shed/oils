module yshd.private_builtins;

import yshd.state : Memory;
import yshd.value : UsageError, YshError;
import std.conv : to;
import std.string : toStringz;
import core.stdc.errno : errno, EINTR, ENOENT;
import core.stdc.string : strerror;
import core.sys.posix.unistd : read, write, close, unlink;
import core.sys.posix.fcntl : open, O_RDONLY;

// Translation of builtin/private_ysh.py. Only explicit builtin/invoke
// selection reaches these; ordinary cat/rm/sleep remain external commands.
int runPrivateBuiltin(string name, string[] words, Memory mem) {
    bool force;
    size_t index;
    for (; index < words.length; ++index) {
        auto word = words[index];
        if (word == "--") { ++index; break; }
        if (word.length < 2 || word[0] != '-') break;
        if (name == "rm" && word == "-f") force = true;
        else throw new UsageError(name ~ ": invalid flag " ~ word);
    }
    words = words[index .. $];
    if (name == "sleep") {
        if (words.length != 1) throw new UsageError("sleep requires one duration");
        double seconds;
        try { seconds = to!double(words[0]); }
        catch (Exception error) { throw new UsageError("sleep: invalid duration"); }
        import std.math : isFinite;
        if (!isFinite(seconds) || seconds < 0) throw new UsageError("sleep: invalid duration");
        import core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC, nanosleep, timespec;
        double now() {
            timespec time;
            if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) throw new YshError("sleep: clock_gettime failed", 2);
            return time.tv_sec + time.tv_nsec / 1e9;
        }
        auto deadline = now() + seconds;
        while (seconds > 0) {
            if (seconds > long.max / 2) throw new UsageError("sleep: duration too large");
            timespec delay;
            delay.tv_sec = cast(typeof(delay.tv_sec))seconds;
            delay.tv_nsec = cast(typeof(delay.tv_nsec))((seconds - delay.tv_sec) * 1e9);
            if (nanosleep(&delay, null) == 0) break;
            if (errno != EINTR) throw new YshError("sleep: " ~ to!string(strerror(errno)), 2);
            mem.traps.runPending(mem);
            seconds = deadline - now();
        }
        return 0;
    }
    if (name == "rm") {
        if (!force && !words.length) throw new UsageError("rm requires at least one file");
        int status;
        foreach (path; words) {
            if (unlink(toStringz(path)) == 0) continue;
            auto error = errno;
            if (force && error == ENOENT) continue;
            mem.errorFile.writeln("rm: ", path, ": ", to!string(strerror(error)));
            status = 1;
        }
        return status;
    }
    assert(name == "cat");
    void copyDescriptor(int input) {
        ubyte[4096] buffer;
        while (true) {
            auto count = read(input, buffer.ptr, buffer.length);
            if (count == 0) break;
            if (count < 0) {
                if (errno == EINTR) continue;
                throw new YshError("cat: read: " ~ to!string(strerror(errno)), 2);
            }
            size_t offset;
            while (offset < count) {
                auto written = write(mem.outputFile.fileno(), buffer.ptr + offset, count - offset);
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) throw new YshError("cat: write: " ~ to!string(strerror(errno)), 2);
                offset += written;
            }
        }
    }
    mem.outputFile.flush();
    if (!words.length) { copyDescriptor(mem.inputFile.fileno()); return 0; }
    int status;
    foreach (path; words) {
        if (path == "-") { copyDescriptor(mem.inputFile.fileno()); continue; }
        auto descriptor = open(toStringz(path), O_RDONLY);
        if (descriptor < 0) {
            mem.errorFile.writeln("cat: ", path, ": ", to!string(strerror(errno)));
            status = 1;
            continue;
        }
        scope (exit) close(descriptor);
        copyDescriptor(descriptor);
    }
    return status;
}
