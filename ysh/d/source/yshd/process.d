module yshd.process;

import std.format : format;
import std.process : Pipe, pipe;
import std.stdio : File;
import std.string : indexOf, replace, split, toStringz;
import std.conv : to;

import yshd.state : Memory, ReturnMode;
import yshd.func_proc : ProcReturn;
import yshd.value : YshError;
import yshd.program : ShellExit, Errexit;
import yshd.trace : TraceScope, TraceProcessKind;

version (Posix) {
    import core.stdc.errno : errno, EINTR, EACCES, ENOENT, ENOTDIR, ENOEXEC;
    import core.stdc.string : strerror;
    import core.sys.posix.sys.types : pid_t;
    import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS,
        WIFSIGNALED, WTERMSIG;
    import core.sys.posix.unistd : fork, _exit, execve, dup2, close, read, write, setpgid,
        sysconf, _SC_OPEN_MAX, getpid;
    import core.sys.posix.poll : poll, pollfd, POLLIN;
    import core.sys.posix.fcntl : fcntl, F_DUPFD;
    import core.sys.posix.signal : signal, SIGPIPE, SIG_DFL, kill, SIGINT, SIGTERM;
}

private int waitSourceChild(int child, Memory mem = null) {
    version (Posix) {
        int status;
        pid_t result;
        while (true) {
            result = waitpid(child, &status, 0);
            if (result >= 0 || errno != EINTR) break;
            if (mem !is null) {
                try { mem.traps.runPending(mem); }
                catch (ShellExit control) {
                    if (control.status == 130) kill(child, SIGINT);
                    waitSourceChild(child);
                    throw control;
                }
            }
        }
        if (result < 0) throw new YshError("waitpid failed for pipeline child");
        if (WIFEXITED(status) || WIFSIGNALED(status)) {
            auto resultStatus = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
            if (mem !is null) mem.trace.processEnd(child, resultStatus, mem);
            if (WIFSIGNALED(status)) reportChildSignal(status, mem);
            return resultStatus;
        }
        throw new YshError("pipeline child has no terminal status");
    } else {
        throw new YshError("source pipelines require POSIX process support");
    }
}

void reportChildSignal(int rawStatus, Memory mem) {
    if (mem is null || !WIFSIGNALED(rawStatus)) return;
    auto number = WTERMSIG(rawStatus);
    if (number == SIGINT) mem.outputFile.writeln();
    else {
        import yshd.libc_patterns : strsignal;
        auto message = strsignal(number);
        if (message !is null) mem.errorFile.writeln(to!string(message));
    }
}

/// The subprogram owns copied shell state, not the parent's job list or traps.
/// Root $$ remains the original shell PID, independently of the OS child PID.
private void prepareSubProgram(Memory mem) {
    mem.trace.newProcess(getpid());
    mem.traps.clearForSubProgram(mem.options.get("errtrace"));
    mem.returnMode = ReturnMode.shell;
    mem.canReplaceProcess = true;
}

private int evaluateChild(string source, Memory mem,
        int delegate(string, Memory) executeStage) {
    int status;
    try { status = executeStage(source, mem); }
    catch (ShellExit control) { status = control.status; }
    catch (ProcReturn control) { status = control.status; }
    catch (YshError error) { mem.errorFile.writeln("ysh-d: ", error.msg); status = error.status; }
    catch (Throwable error) { mem.errorFile.writeln("ysh-d: ", error.msg); status = 3; }
    mem.outputFile.flush();
    mem.errorFile.flush();
    return status;
}

/// Background pipelines launch every stage as a direct child of this shell.
/// The job's public wait PID is its last stage, not an intermediate evaluator.
int runSourceJob(string[] stages, Memory mem,
        int delegate(string, Memory) executeStage, bool background) {
    if (!stages.length) throw new YshError("job needs a command");
    auto links = new Pipe[stages.length - 1];
    foreach (ref link; links) link = pipe();
    int[] children;
    string[] descriptions;
    int group;
    bool started;
    mem.outputFile.flush();
    mem.errorFile.flush();
    scope (exit) {
        foreach (ref link; links) link.close();
        if (!started) foreach (child; children) { kill(child, SIGTERM); waitSourceChild(child); }
    }
    foreach (index, stage; stages) {
        auto child = fork();
        if (child < 0) throw new YshError("fork failed for job: " ~ to!string(strerror(errno)), 2);
        if (child == 0) {
            try {
                if (mem.jobs.controlEnabled) setpgid(0, group);
                signal(SIGPIPE, SIG_DFL);
                prepareSubProgram(mem);
                if (index) mem.inputFile = links[index - 1].readEnd;
                if (index + 1 < stages.length) mem.outputFile = links[index].writeEnd;
                foreach (i, ref link; links) {
                    if (!index || i != index - 1) link.readEnd.close();
                    if (index + 1 == stages.length || i != index) link.writeEnd.close();
                }
                _exit(evaluateChild(stage, mem, executeStage));
            } catch (Throwable error) {
                mem.errorFile.writeln("ysh-d: child setup: ", error.msg);
                mem.errorFile.flush();
                _exit(2);
            }
        }
        if (mem.jobs.controlEnabled) {
            if (!group) group = child;
            // Both sides set the group, closing the parent/exec race.
            setpgid(child, group);
        }
        mem.trace.processStart(child, stages.length > 1 ? TraceProcessKind.pipelinePart :
            background ? TraceProcessKind.fork : TraceProcessKind.forkWait, [], mem);
        children ~= child;
        descriptions ~= "Simple";
    }
    foreach (ref link; links) link.close();
    auto job = mem.jobs.add(children, group, background, descriptions);
    started = true;
    if (background) {
        mem.lastBackgroundPid = job.pidForWait();
        return 0;
    }
    return mem.jobs.waitFor(job, mem, false);
}

/// Launch all producer stages before running the final stage in the current
/// interpreter, matching YSH's last-stage variable binding. Real pipes provide
/// streaming and backpressure. Each producer gets process-isolated shell state.
int runSourcePipeline(string[] stages, Memory mem,
        int delegate(string, Memory) executeStage) {
    if (stages.length == 0) throw new YshError("pipeline needs a command");
    if (stages.length == 1) return executeStage(stages[0], mem);
    auto traceScope = TraceScope(mem, "pipeline");
    ++mem.errTrapSuppression;
    scope (exit) --mem.errTrapSuppression;
    version (Posix) {
        auto links = new Pipe[stages.length - 1];
        int[] children;
        int[] statuses = new int[stages.length];
        auto originalInput = mem.inputFile;
        scope (exit) mem.inputFile = originalInput;
        mem.outputFile.flush();
        mem.errorFile.flush();
        scope (exit) {
            foreach (ref link; links) link.close();
            // Also reap producers when the final command exits or throws.
            foreach (child; children) if (child > 0) waitSourceChild(child);
        }
        foreach (ref link; links) link = pipe();
        foreach (index; 0 .. stages.length - 1) {
            auto child = fork();
            if (child < 0) throw new YshError("fork failed for pipeline stage");
            if (child == 0) {
                signal(SIGPIPE, SIG_DFL);
                prepareSubProgram(mem);
                if (index > 0) mem.inputFile = links[index - 1].readEnd;
                mem.outputFile = links[index].writeEnd;
                foreach (linkIndex, ref link; links) {
                    if (index == 0 || linkIndex != index - 1) link.readEnd.close();
                    if (linkIndex != index) link.writeEnd.close();
                }
                int status;
                try {
                    status = executeStage(stages[index], mem);
                } catch (ShellExit control) {
                    status = control.status;
                } catch (ProcReturn control) {
                    status = control.status;
                } catch (YshError error) {
                    mem.errorFile.writeln("ysh-d: ", error.msg);
                    status = error.status;
                } catch (Throwable error) {
                    mem.errorFile.writeln("ysh-d: ", error.msg);
                    mem.errorFile.flush();
                    status = 3;
                }
                mem.outputFile.flush();
                mem.errorFile.flush();
                _exit(status);
            }
            mem.trace.processStart(child, TraceProcessKind.pipelinePart, [], mem);
            children ~= child;
        }
        foreach (index, ref link; links) {
            link.writeEnd.close();
            if (index + 1 < links.length) link.readEnd.close();
        }
        mem.inputFile = links[$ - 1].readEnd;
        try {
            statuses[$ - 1] = executeStage(stages[$ - 1], mem);
        } catch (Errexit failed) {
            // A stage still stops within a compound command under errexit.
            // Only its terminal status is deferred to the pipeline owner.
            // Explicit exit/return remain control flow in the current shell.
            statuses[$ - 1] = failed.status;
        }
        mem.inputFile = originalInput;
        links[$ - 1].readEnd.close();
        foreach (index, ref child; children) {
            statuses[index] = waitSourceChild(child, mem);
            if (statuses[index] == 141 && mem.options.get("sigpipe_status_ok")) statuses[index] = 0;
            child = 0;
        }
        children = [];
        mem.pipelineStatus = statuses.dup;
        if (mem.pipefail) {
            foreach_reverse (status; statuses) if (status != 0) return status;
        }
        return statuses[$ - 1];
    } else {
        throw new YshError("source pipelines require POSIX process support");
    }
}

struct SourceCapture {
    string stdoutText;
    string stderrText;
    int status;
}

/// core/executor.py:CaptureStdout/Capture3 share process isolation and the
/// inherit_errexit rule. Poll both output descriptors while the child runs:
/// draining one stream to EOF first can deadlock on a full second pipe.
SourceCapture captureSource(string source, Memory mem,
        int delegate(string, Memory) executeStage, bool captureErrors = false) {
    version (Posix) {
        auto links = new Pipe[captureErrors ? 2 : 1];
        foreach (ref link; links) link = pipe();
        mem.outputFile.flush();
        mem.errorFile.flush();
        auto child = fork();
        if (child < 0) {
            foreach (ref link; links) link.close();
            throw new YshError("fork failed for command substitution");
        }
        if (child == 0) {
            signal(SIGPIPE, SIG_DFL);
            prepareSubProgram(mem);
            foreach (ref link; links) link.readEnd.close();
            mem.outputFile = links[0].writeEnd;
            if (captureErrors) mem.errorFile = links[1].writeEnd;
            mem.returnMode = ReturnMode.shell;
            if (!mem.options.get("inherit_errexit")) mem.errexit = false;
            int status;
            try {
                status = executeStage(source, mem);
            } catch (ShellExit control) {
                status = control.status;
            } catch (ProcReturn control) {
                status = control.status;
            } catch (YshError error) {
                mem.errorFile.writeln("ysh-d: ", error.msg);
                status = error.status;
            } catch (Throwable error) {
                mem.errorFile.writeln("ysh-d: ", error.msg);
                mem.errorFile.flush();
                status = 3;
            }
            mem.outputFile.flush();
            mem.errorFile.flush();
            _exit(status);
        }
        mem.trace.processStart(child, TraceProcessKind.commandSub, [], mem);
        foreach (ref link; links) link.writeEnd.close();
        bool reaped;
        scope (exit) {
            foreach (ref link; links) link.close();
            if (!reaped) waitSourceChild(child);
        }
        pollfd[] descriptors;
        foreach (ref link; links) descriptors ~= pollfd(link.readEnd.fileno(), POLLIN, 0);
        auto remaining = descriptors.length;
        SourceCapture result;
        char[4096] buffer;
        while (remaining) {
            int ready;
            do {
                ready = poll(descriptors.ptr, descriptors.length, -1);
                if (ready < 0 && errno == EINTR) mem.traps.runPending(mem);
            } while (ready < 0 && errno == EINTR);
            if (ready < 0) throw new YshError("Oils I/O error (poll): " ~ to!string(strerror(errno)), 2);
            foreach (index, ref descriptor; descriptors) {
                if (descriptor.fd < 0 || descriptor.revents == 0) continue;
                auto count = read(descriptor.fd, buffer.ptr, buffer.length);
                if (count < 0) {
                    if (errno == EINTR) continue;
                    throw new YshError("Oils I/O error (read): " ~ to!string(strerror(errno)), 2);
                }
                if (count == 0) {
                    descriptor.fd = -1;
                    links[index].readEnd.close();
                    --remaining;
                } else if (index == 0) result.stdoutText ~= buffer[0 .. cast(size_t)count];
                else result.stderrText ~= buffer[0 .. cast(size_t)count];
            }
        }
        result.status = waitSourceChild(child, mem);
        reaped = true;
        return result;
    } else {
        throw new YshError("command substitution requires POSIX process support");
    }
}

/// Shell command substitution drops NUL bytes; Capture3 retains all bytes.
/// Its terminal status belongs to the parent shell's command-substitution
/// register, unlike the expression-level capture methods.
string captureSourceOutput(string source, Memory mem,
        int delegate(string, Memory) executeStage) {
    auto result = captureSource(source, mem, executeStage);
    // With command_sub_errexit, RunCommandSub reports failure directly and
    // leaves the caller's status register alone. The POSIX path records the
    // substitution status for assignment-only commands instead.
    if (!mem.options.get("command_sub_errexit")) mem.lastStatus = result.status;
    ++mem.commandSubEpoch;
    mem.commandSubLastStatus = result.status;
    return result.stdoutText.replace("\0", "");
}

private int launchExternal(string[] argv, File input, File output,
        File errors, string[string] childEnvironment, bool replaceProcess = false, bool useDefaultPath = false) {
    if (argv.length == 0 || argv[0].length == 0) {
        throw new YshError("external command needs a program name");
    }

    version (Posix) {
        // Resolve PATH from the shell's environment, not the D host process.
        // Passing an explicit environment to std.process does not do this and
        // merges deleted host variables back into the child unless newEnv is
        // selected. Keep both responsibilities at this POSIX boundary.
        const(char)*[] arguments;
        foreach (word; argv) arguments ~= toStringz(word);
        arguments ~= null;
        const(char)*[] environment;
        foreach (name, value; childEnvironment)
            environment ~= toStringz(name ~ "=" ~ value);
        environment ~= null;
        string[] paths;
        if (argv[0].indexOf('/') >= 0) paths = [argv[0]];
        else {
            auto path = "PATH" in childEnvironment;
            auto searchPath = useDefaultPath ? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" :
                (path is null ? "/bin:/usr/bin" : *path);
            foreach (directory; searchPath.split(":"))
                paths ~= directory.length ? directory ~ "/" ~ argv[0] : argv[0];
        }
        output.flush();
        errors.flush();
        if (!replaceProcess) {
            auto child = fork();
            if (child < 0) throw new YshError("fork failed for external command");
            if (child != 0) return child;
        }
        signal(SIGPIPE, SIG_DFL);
        // Snapshot all three sources before dup2, preserving 2>&1 >file and
        // descriptor cycles even when their source is an original stdio fd.
        int[3] sources = [input.fileno(), output.fileno(), errors.fileno()];
        int[3] copies;
        foreach (index, source; sources) {
            copies[index] = fcntl(source, F_DUPFD, 3);
            if (copies[index] < 0) _exit(126);
        }
        foreach (index, copy; copies) if (dup2(copy, cast(int)index) < 0) _exit(126);
        version (linux) {
            import core.sys.linux.unistd : closefrom;
            closefrom(3);
        } else {
            auto limit = sysconf(_SC_OPEN_MAX);
            for (int descriptor = 3; descriptor < limit; ++descriptor) close(descriptor);
        }
        int lastError = ENOENT;
        bool denied;
        foreach (path; paths) {
            execve(toStringz(path), arguments.ptr, environment.ptr);
            lastError = errno;
            if (lastError == ENOEXEC) {
                // Reference ExternalProgram._Exec retries executable files
                // without a shebang through /bin/sh. This is the external-file
                // OS boundary; YSH program text is always parsed by D.
                const(char)*[] retry = [toStringz("/bin/sh"), toStringz(path)];
                retry ~= arguments[1 .. $];
                execve(toStringz("/bin/sh"), retry.ptr, environment.ptr);
                lastError = errno;
                break;
            }
            if (lastError == EACCES) { denied = true; continue; }
            if (lastError != ENOENT && lastError != ENOTDIR) break;
        }
        if (denied && (lastError == ENOENT || lastError == ENOTDIR)) lastError = EACCES;
        auto message = format("ysh-d: %s: %s\n", argv[0], to!string(strerror(lastError)));
        write(2, message.ptr, message.length);
        _exit(lastError == EACCES ? 126 : 127);
        assert(0);
    } else {
        throw new YshError("external commands require POSIX process support");
    }
}

/// Execute an already-parsed argv vector at the operating-system boundary.
///
/// This deliberately receives words rather than source text: YSH parsing and
/// expansion stay in the D implementation, while process creation itself is a
/// normal POSIX/library boundary.
int runExternal(string[] argv, Memory mem, bool useDefaultPath = false) {
    auto environment = mem.childEnvironment();
    auto replacing = mem.canReplaceProcess && !mem.traps.hasActions();
    if (replacing) mem.trace.exec(argv, mem);
    auto child = launchExternal(argv, mem.inputFile, mem.outputFile,
        mem.errorFile, environment, replacing, useDefaultPath);
    mem.trace.processStart(child, TraceProcessKind.external, argv, mem);
    return waitSourceChild(child, mem);
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

    int[] children;
    children.reserve(commands.length);
    try {
        foreach (index, command; commands) {
            auto input = index == 0 ? mem.inputFile : links[index - 1].readEnd;
            auto output = index + 1 == commands.length
                ? mem.outputFile
                : links[index].writeEnd;
            children ~= launchExternal(command, input, output, mem.errorFile,
                mem.childEnvironment());
        }
    } catch (Exception error) {
        foreach (ref link; links) {
            link.close();
        }
        foreach (child; children) {
            waitSourceChild(child);
        }
        throw error;
    }

    // Only the children should retain the pipe descriptors. Closing the
    // parent's copies is required for readers to observe EOF.
    foreach (ref link; links) {
        link.close();
    }

    int status;
    int[] statuses;
    foreach (index, child; children) {
        auto childStatus = waitSourceChild(child, mem);
        if (childStatus == 141 && mem.options.get("sigpipe_status_ok")) childStatus = 0;
        statuses ~= childStatus;
        if ((mem.pipefail && childStatus != 0) ||
                (!mem.pipefail && index + 1 == children.length)) {
            status = childStatus;
        }
    }
    mem.pipelineStatus = statuses;
    return status;
}

unittest {
    // Keep unit tests independent of PATH and process availability. Process
    // execution is exercised by the CLI workflow on the actual runner.
}
