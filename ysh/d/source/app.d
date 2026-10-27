module app;

import std.file : FileException, exists, read;
import std.exception : ErrnoException;
import std.stdio : stderr, stdin, writeln;
import std.string : join;
import std.path : baseName;
import core.stdc.locale : setlocale, LC_CTYPE, LC_COLLATE;

import yshd.expr : ParseError, evaluate;
import yshd.lexer : LexError;
import yshd.program : ShellExit, executeProgram, parseProgram;
import yshd.func_proc : ProcReturn;
import yshd.state : Memory, ReturnMode;
import yshd.options : ShellOptions;
import yshd.value : UsageError, YshError, repr;

private Memory shellMemory(string argumentZero, string[] arguments,
        ShellOptions options = null) {
    auto mem = new Memory();
    mem.options = options is null ? new ShellOptions(true) : options;
    mem.initializeShellEnvironment();
    mem.initializeDirectory();
    mem.initializeArguments(argumentZero, arguments);
    return mem;
}

private int runBatchSource(string source, Memory mem) {
    mem.traps.initializeMain();
    scope (exit) mem.traps.restore();
    int status;
    try { executeProgram(source, mem); status = mem.lastStatus; }
    catch (ShellExit control) { status = control.status; }
    catch (ProcReturn control) { status = control.status; }
    catch (LexError error) { mem.errorFile.writeln("ysh-d: ", error.msg); status = 2; }
    catch (YshError error) { mem.errorFile.writeln("ysh-d: ", error.msg); status = error.status; }
    catch (FileException error) { mem.errorFile.writeln("ysh-d: ", error.msg); status = 1; }
    catch (ErrnoException error) { mem.errorFile.writeln("ysh-d: ", error.msg); status = 1; }
    return mem.traps.finish(mem, status);
}

int main(string[] args) {
    // Match reference startup: numeric formatting stays in the C locale,
    // while libc's regex/character-width operations use LC_CTYPE from ENV.
    if (setlocale(LC_CTYPE, "") is null) stderr.writeln("ysh-d: setlocale(LC_CTYPE) failed");
    auto applet = baseName(args[0]);
    if ((applet == "osh" || applet == "osh-d") && setlocale(LC_COLLATE, "") is null)
        stderr.writeln("ysh-d: setlocale(LC_COLLATE) failed");
    bool parseOnly;
    try {
        size_t sourceIndex = 1;
        bool literalPath;
        bool commandString;
        // The reference selects its initial option group before applying CLI
        // flags. The shared OSH mode is also needed by inherited upgrade tests.
        auto executableName = baseName(args[0]);
        auto options = new ShellOptions(executableName != "osh" && executableName != "osh-d");
        while (sourceIndex < args.length) {
            auto option = args[sourceIndex];
            if (option == "-n") {
                options.setOld("noexec", true);
                ++sourceIndex;
            } else if (option == "--ast-format" || option == "--ast-format=none") {
                if (option == "--ast-format") {
                    ++sourceIndex;
                    if (sourceIndex == args.length || args[sourceIndex] != "none") {
                        stderr.writeln("ysh-d: --ast-format currently requires none");
                        return 2;
                    }
                }
                ++sourceIndex;
            } else if (option == "--") {
                ++sourceIndex;
                literalPath = true;
                break;
            } else if (option.length > 1 && (option[0] == '-' || option[0] == '+')) {
                bool enabled = option[0] == '-';
                for (size_t flagIndex = 1; flagIndex < option.length; ++flagIndex) {
                    auto flag = option[flagIndex];
                    if (flag == 'c' && enabled) {
                        commandString = true;
                    } else if (flag == 'o' || flag == 'O') {
                        if (flagIndex + 1 != option.length || sourceIndex + 1 == args.length)
                            throw new UsageError("shell option flag requires an option name");
                        ++sourceIndex;
                        if (flag == 'o') options.setOld(args[sourceIndex], enabled);
                        else options.set(args[sourceIndex], enabled);
                    } else {
                        options.setOld(ShellOptions.shortName(flag), enabled);
                    }
                }
                ++sourceIndex;
                if (commandString) break;
            } else {
                break;
            }
        }
        parseOnly = options.get("noexec");

        if (!commandString && (sourceIndex == args.length || (!literalPath && args[sourceIndex] == "-"))) {
            // The Oils spec harness invokes shells without argv and sends each
            // test case on stdin. Batch stdin is therefore a first-class YSH
            // entry path rather than an error case.
            string source;
            while (true) {
                auto line = stdin.readln();
                if (line.length == 0) {
                    break;
                }
                source ~= line;
            }

            if (parseOnly) {
                parseProgram(source, ReturnMode.shell, options);
                return 0;
            }
            auto mem = shellMemory(args[0], args[sourceIndex < args.length ? sourceIndex + 1 : sourceIndex .. $], options);
            return runBatchSource(source, mem);
        }

        if (commandString) {
            if (args.length == sourceIndex) {
                stderr.writeln("ysh-d: -c requires program text");
                return 2;
            }
            // Only the next argv member is source. Later words initialize
            // $0 and ARGV; they must never be joined into executable text.
            auto source = args[sourceIndex];
            if (parseOnly) {
                parseProgram(source, ReturnMode.shell, options);
                return 0;
            }
            auto argumentZero = args.length > sourceIndex + 1 ? args[sourceIndex + 1] : args[0];
            auto arguments = args.length > sourceIndex + 2 ? args[sourceIndex + 2 .. $] : [];
            auto mem = shellMemory(argumentZero, arguments, options);
            return runBatchSource(source, mem);
        }

        if (parseOnly || literalPath || exists(args[sourceIndex]) || args.length > sourceIndex + 1) {
            auto source = cast(string)read(args[sourceIndex]);
            if (parseOnly) {
                parseProgram(source, ReturnMode.shell, options);
                return 0;
            }
            auto mem = shellMemory(args[sourceIndex], args[sourceIndex + 1 .. $], options);
            mem.pushSourceDirectory(args[sourceIndex]);
            return runBatchSource(source, mem);
        }

        auto source = args[sourceIndex .. $].join(" ");
        writeln(repr(evaluate(source)));
        return 0;
    } catch (ShellExit control) {
        return control.status;
    } catch (ProcReturn control) {
        return control.status;
    } catch (ParseError error) {
        stderr.writeln("ysh-d: ", error.msg);
        return 2;
    } catch (LexError error) {
        stderr.writeln("ysh-d: ", error.msg);
        return 2;
    } catch (UsageError error) {
        stderr.writeln("ysh-d: ", error.msg);
        return 2;
    } catch (YshError error) {
        stderr.writeln("ysh-d: ", error.msg);
        return parseOnly ? 2 : error.status;
    } catch (FileException error) {
        stderr.writeln("ysh-d: ", error.msg);
        return 1;
    }
}

unittest {
    assert(main(["ysh-d", "-c", "case ('μx') { / <capture dot> / { assert [_group(1) === 'μ'] } }"]) == 0);
    // CLI words after -c belong to argv, even when they look executable.
    assert(main(["ysh-d", "-c", "true", "not-source", "echo", "wrong"]) == 0);
    assert(main(["ysh-d", "-c", "true;", "exit 91"]) == 0);
    assert(main(["ysh-d", "-c", "false"]) == 1);
    assert(main(["ysh-d", "+e", "-c", "false; echo -n"]) == 0);
    assert(main(["ysh-d", "+e", "-c", "false; write -n"]) == 0);
    assert(main(["ysh-d", "-c", "false; echo -n"]) == 1);
    assert(main(["ysh-d", "-n", "+n", "-c", "exit 23"]) == 23);
    assert(main(["ysh-d", "-c", "set -n; exit 23"]) == 0);
    assert(main(["ysh-d", "-c", "exit 23"]) == 23);
    assert(main(["ysh-d", "--ast-format", "none", "-n", "-c",
        "exit 91; var x = missing(1 / 0); echo $undefined; source /no/such/file"]) == 0);
    assert(main(["ysh-d", "-n", "-c", "if (false) { var x = 1 + }"]) == 2);
    assert(main(["ysh-d", "-n", "-c", "proc unused { echo $[1 +] }"]) == 2);
    auto mem = shellMemory("script with spaces.grease", ["one word", "two"]);
    assert(mem.argumentZero == "script with spaces.grease");
    assert(mem.get("ARGV").listValue.length == 2);
    assert(mem.get("ARGV").listValue.items[0].stringValue == "one word");
}

version (linux) unittest {
    import std.conv : to;
    import std.stdio : File;
    // A real file plus arguments used to enter the expression diagnostic path.
    // Keep executable-looking argument bytes out of the parsed source.
    auto script = File.tmpfile();
    script.write("assert [len(ARGV) === 2]\n",
        "assert [ARGV[0] === 'one word']\n",
        "assert [ARGV[1] === 'exit 91']\n");
    script.flush();
    auto path = "/proc/self/fd/" ~ to!string(script.fileno());
    assert(main(["ysh-d", path, "one word", "exit 91"]) == 0);
    auto failedScript = File.tmpfile();
    failedScript.write("false\n");
    failedScript.flush();
    auto failedPath = "/proc/self/fd/" ~ to!string(failedScript.fileno());
    assert(main(["ysh-d", failedPath]) == 1);
}
