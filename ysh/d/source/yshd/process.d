module yshd.process;

import std.format : format;
import std.process : ProcessException, spawnProcess, wait;

import yshd.state : Memory;
import yshd.value : YshError;

/// Execute an already-parsed argv vector at the operating-system boundary.
///
/// This deliberately receives words rather than source text: YSH parsing and
/// expansion stay in the D implementation, while process creation itself is a
/// normal POSIX/library boundary.
int runExternal(string[] argv, Memory mem) {
    if (argv.length == 0 || argv[0].length == 0) {
        throw new YshError("external command needs a program name");
    }

    try {
        auto pid = spawnProcess(argv, mem.childEnvironment());
        return wait(pid);
    } catch (ProcessException error) {
        throw new YshError(format("%s: %s", argv[0], error.msg));
    }
}

unittest {
    // Keep unit tests independent of PATH and process availability.  Process
    // execution is exercised by the CLI workflow on the actual runner.
}
