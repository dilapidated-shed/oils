module yshd.process;

import std.format : format;
import std.process : Config, Pid, Pipe, ProcessException, pipe, spawnProcess, wait;
import std.stdio : File;

import yshd.state : Memory;
import yshd.value : YshError;

private Pid spawn(string[] argv, File input, File output,
        Memory mem) {
    if (argv.length == 0 || argv[0].length == 0) {
        throw new YshError("external command needs a program name");
    }

    try {
        return spawnProcess(argv, input, output, mem.errorFile,
            mem.childEnvironment(),
            Config.retainStdin | Config.retainStdout | Config.retainStderr);
    } catch (ProcessException error) {
        throw new YshError(format("%s: %s", argv[0], error.msg));
    }
}

/// Execute an already-parsed argv vector at the operating-system boundary.
///
/// This deliberately receives words rather than source text: YSH parsing and
/// expansion stay in the D implementation, while process creation itself is a
/// normal POSIX/library boundary.
int runExternal(string[] argv, Memory mem) {
    auto pid = spawn(argv, mem.inputFile, mem.outputFile, mem);
    return wait(pid);
}

/// Execute a pipeline of already-expanded argv vectors.
///
/// Pipes are created by the D runtime and connected directly between child
/// processes. No POSIX shell is invoked to reinterpret YSH source.
int runPipeline(string[][] commands, Memory mem) {
    if (commands.length == 0) {
        throw new YshError("pipeline needs at least one command");
    }
    if (commands.length == 1) {
        return runExternal(commands[0], mem);
    }

    Pipe[] links;
    links.reserve(commands.length - 1);
    foreach (_; 0 .. commands.length - 1) {
        links ~= pipe();
    }

    Pid[] children;
    children.reserve(commands.length);
    try {
        foreach (index, command; commands) {
            auto input = index == 0 ? mem.inputFile : links[index - 1].readEnd;
            auto output = index + 1 == commands.length
                ? mem.outputFile
                : links[index].writeEnd;
            children ~= spawn(command, input, output, mem);
        }
    } catch (Exception error) {
        foreach (ref link; links) {
            link.close();
        }
        foreach (child; children) {
            wait(child);
        }
        throw error;
    }

    // Only the children should retain the pipe descriptors. Closing the
    // parent's copies is required for readers to observe EOF.
    foreach (ref link; links) {
        link.close();
    }

    int status;
    foreach (index, child; children) {
        auto childStatus = wait(child);
        if (index + 1 == children.length) {
            status = childStatus;
        }
    }
    return status;
}

unittest {
    // Keep unit tests independent of PATH and process availability. Process
    // execution is exercised by the CLI workflow on the actual runner.
}
