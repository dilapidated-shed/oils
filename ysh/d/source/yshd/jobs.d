module yshd.jobs;

import std.conv : to;
import std.string : startsWith;
import core.stdc.errno : errno, EINTR, ECHILD;
import core.stdc.string : strerror;
import core.sys.posix.sys.wait;
import core.sys.posix.signal : kill, SIGCONT;
import core.sys.posix.unistd : getpgrp, tcsetpgrp, isatty;

import yshd.state : Memory;
import yshd.traps : TrapState;
import yshd.value : YshError, UsageError;

enum ChildState { running, stopped, done }

/// One background process or pipeline. PidForWait is the last pipeline PID;
/// the process group leader is separate, as in core/process.py.
class Job {
    int id;
    int[] pids;
    int[] statuses;
    ChildState[] states;
    string[] descriptions;
    int group;
    bool visible;
    bool consumed;

    this(int[] pids, int group, bool visible, string[] descriptions) {
        this.pids = pids;
        this.group = group;
        this.visible = visible;
        this.descriptions = descriptions;
        statuses.length = pids.length;
        states.length = pids.length;
    }

    int pidForWait() { return pids[$ - 1]; }
    bool done() { foreach (state; states) if (state != ChildState.done) return false; return true; }
    bool running() { foreach (state; states) if (state == ChildState.running) return true; return false; }
    int status() {
        if (!done()) foreach (i, state; states) if (state == ChildState.stopped) return statuses[i];
        return statuses[$ - 1];
    }
}

class JobTable {
    bool controlEnabled;
    private Job[] jobs;
    private int nextId = 1;

    Job add(int[] pids, int group, bool visible, string[] descriptions) {
        auto job = new Job(pids, group, visible, descriptions);
        if (visible) job.id = nextId++;
        jobs ~= job;
        return job;
    }

    private Job record(int pid, int rawStatus) {
        foreach (job; jobs) foreach (i, child; job.pids) if (child == pid && job.states[i] != ChildState.done) {
            if (WIFEXITED(rawStatus)) { job.states[i] = ChildState.done; job.statuses[i] = WEXITSTATUS(rawStatus); }
            else if (WIFSIGNALED(rawStatus)) { job.states[i] = ChildState.done; job.statuses[i] = 128 + WTERMSIG(rawStatus); }
            else if (WIFSTOPPED(rawStatus)) { job.states[i] = ChildState.stopped; job.statuses[i] = 128 + WSTOPSIG(rawStatus); }
            return job;
        }
        return null;
    }

    private void consume(Job job) {
        if (job.done()) job.consumed = true;
    }

    private int waitOne(int pid, out Job changed, Memory mem, bool nonblocking = false) {
        changed = null;
        while (true) {
            int raw;
            auto result = waitpid(pid, &raw, WUNTRACED | (nonblocking ? WNOHANG : 0));
            if (result > 0) {
                import yshd.process : reportChildSignal;
                reportChildSignal(raw, mem);
                if (WIFEXITED(raw) || WIFSIGNALED(raw))
                    mem.trace.processEnd(result, WIFEXITED(raw) ? WEXITSTATUS(raw) : 128 + WTERMSIG(raw), mem);
                changed = record(result, raw); return 0;
            }
            if (result == 0) return -1;
            if (errno == ECHILD) return -1;
            if (errno == EINTR) {
                auto number = TrapState.interruptSignal();
                if (number) return 128 + number;
                continue;
            }
            throw new YshError("waitpid failed: " ~ to!string(strerror(errno)), 2);
        }
    }

    int waitFor(Job job, Memory mem, bool interruptible = true) {
        while (!job.done() && job.running()) {
            int pid;
            foreach (i, state; job.states) if (state == ChildState.running) { pid = job.pids[i]; break; }
            Job changed;
            auto interrupted = waitOne(pid, changed, mem);
            if (interrupted > 0) {
                if (interruptible) return interrupted;
                mem.traps.runPending(mem);
            } else if (interrupted == -1) {
                // An untracked reaper must not manufacture a successful status.
                throw new YshError("child status is unavailable for PID " ~ to!string(pid), 127);
            }
        }
        auto status = job.status();
        consume(job);
        return status;
    }

    private Job find(string word) {
        if (!word.length || word[0] == '%') {
            if (!word.length || word == "%" || word == "%%" || word == "%+") {
                foreach_reverse (job; jobs) if (!job.consumed && job.visible) return job;
                return null;
            }
            if (word == "%-") {
                bool skipped;
                foreach_reverse (job; jobs) if (!job.consumed && job.visible) {
                    if (skipped) return job;
                    skipped = true;
                }
                return null;
            }
            int id;
            try { id = to!int(word[1 .. $]); }
            catch (Exception error) { return null; }
            foreach (job; jobs) if (!job.consumed && job.visible && job.id == id) return job;
        } else {
            int pid;
            try { pid = to!int(word); }
            catch (Exception error) { throw new UsageError("expected PID or jobspec, got '" ~ word ~ "'"); }
            foreach (job; jobs) if (!job.consumed && job.pidForWait() == pid) return job;
        }
        return null;
    }

    int waitBuiltin(string[] words, Memory mem) {
        bool next, all, verbose;
        size_t index;
        for (; index < words.length; ++index) {
            auto word = words[index];
            if (word == "--") { ++index; break; }
            if (word == "-n") next = true;
            else if (word == "--all") all = true;
            else if (word == "--verbose") verbose = true;
            else if (word.length > 1 && word[0] == '-') throw new UsageError("wait: invalid flag " ~ word);
            else break;
        }
        auto ids = words[index .. $];
        if (ids.length) {
            Job[] selected;
            foreach (word; ids) {
                auto job = find(word);
                if (job is null) {
                    if (word.startsWith("%")) throw new UsageError("expected PID or jobspec, got '" ~ word ~ "'");
                    mem.errorFile.writeln("Job ", word, " wasn't found");
                    return 127;
                }
                selected ~= job;
            }
            int status;
            foreach (job; selected) {
                status = waitFor(job, mem);
                if (!job.done() || (status >= 128 && TrapState.interruptSignal())) break;
            }
            return status;
        }
        bool haveRunning;
        foreach (job; jobs) if (!job.consumed && job.running()) haveRunning = true;
        if (!haveRunning) return next ? 127 : 0;
        int result;
        while (true) {
            Job changed;
            auto interrupted = waitOne(-1, changed, mem);
            if (interrupted > 0) return interrupted;
            if (interrupted < 0) return next ? 127 : result;
            if (changed !is null && changed.done()) {
                auto code = changed.status();
                consume(changed);
                if (verbose) mem.errorFile.writeln("(wait) PID ", changed.pidForWait(), " exited with status ", code);
                if (next) return code;
                if (all && code != 0) {
                    result = 1;
                    if (verbose) mem.errorFile.writeln("wait --all: will fail with status 1");
                }
            }
            haveRunning = false;
            foreach (job; jobs) if (!job.consumed && job.running()) haveRunning = true;
            if (!haveRunning) return result;
        }
    }

    int jobsBuiltin(string[] words, Memory mem) {
        bool pidOnly, showDebug;
        foreach (word; words) {
            if (word == "--" || word == "-l") continue;
            if (word == "-p") pidOnly = true;
            else if (word == "--debug") showDebug = true;
            else throw new UsageError("jobs: unexpected argument " ~ word);
        }
        foreach (job; jobs) if (job.visible && !job.consumed) {
            if (pidOnly) { mem.outputFile.writeln(job.pids[0]); continue; }
            foreach (i, pid; job.pids) {
                // core/process.py:Pipeline.DisplayJob currently omits its
                // leader in long/default style. Preserve the reference.
                if (job.pids.length > 1 && i == 0) continue;
                auto id = i == 0 ? "%" ~ to!string(job.id) : "  ";
                auto state = job.states[i] == ChildState.running ? "Running"
                    : job.states[i] == ChildState.done ? "Done" : "Stopped";
                mem.outputFile.writef("%s %d %7s [subprog] %s\n", id, pid, state, job.descriptions[i]);
            }
        }
        if (showDebug) {
            mem.outputFile.writeln();
            mem.outputFile.writeln("[process debug info]");
            foreach (job; jobs) foreach (i, pid; job.pids)
                mem.outputFile.writeln("PID ", pid, " status ", job.statuses[i]);
        }
        return 0;
    }

    int foreground(string[] words, Memory mem) {
        auto job = find(words.length ? words[0] : "");
        if (job is null || !job.group) { mem.errorFile.writeln("fg: No job to put in the foreground"); return 1; }
        auto tty = mem.inputFile.fileno();
        auto terminal = isatty(tty) != 0;
        if (terminal && tcsetpgrp(tty, job.group) < 0)
            throw new YshError("cannot give terminal to job: " ~ to!string(strerror(errno)), 2);
        scope (exit) { if (terminal) tcsetpgrp(tty, getpgrp()); }
        if (kill(-job.group, SIGCONT) < 0) { mem.errorFile.writeln("fg: ", to!string(strerror(errno))); return 1; }
        foreach (ref state; job.states) if (state == ChildState.stopped) state = ChildState.running;
        return waitFor(job, mem, false);
    }
}
