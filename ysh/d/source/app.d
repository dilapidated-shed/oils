module app;

import std.file : FileException, exists, readText;
import std.stdio : stderr, stdin, writeln;
import std.string : join;

import yshd.expr : evaluate;
import yshd.program : ShellExit, executeProgram;
import yshd.state : Memory;
import yshd.value : YshError, repr;

private Memory shellMemory(string argumentZero, string[] arguments) {
    auto mem = new Memory();
    mem.initializeArguments(argumentZero, arguments);
    return mem;
}

int main(string[] args) {
    try {
        if (args.length < 2) {
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

            auto mem = shellMemory(args[0], []);
            executeProgram(source, mem);
            return mem.lastStatus;
        }

        if (args[1] == "-c") {
            if (args.length < 3) {
                stderr.writeln("ysh-d: -c requires program text");
                return 2;
            }
            // Only the next argv member is source. Later words initialize
            // $0 and ARGV; they must never be joined into executable text.
            auto source = args[2];
            auto argumentZero = args.length > 3 ? args[3] : args[0];
            auto arguments = args.length > 4 ? args[4 .. $] : [];
            auto mem = shellMemory(argumentZero, arguments);
            executeProgram(source, mem);
            return mem.lastStatus;
        }

        if (exists(args[1]) || args.length > 2) {
            auto mem = shellMemory(args[1], args[2 .. $]);
            executeProgram(readText(args[1]), mem);
            return mem.lastStatus;
        }

        auto source = args[1 .. $].join(" ");
        writeln(repr(evaluate(source)));
        return 0;
    } catch (ShellExit control) {
        return control.status;
    } catch (YshError error) {
        stderr.writeln("ysh-d: ", error.msg);
        return 3;
    } catch (FileException error) {
        stderr.writeln("ysh-d: ", error.msg);
        return 1;
    }
}

unittest {
    // CLI words after -c belong to argv, even when they look executable.
    assert(main(["ysh-d", "-c", "true", "not-source", "echo", "wrong"]) == 0);
    assert(main(["ysh-d", "-c", "true;", "exit 91"]) == 0);
    assert(main(["ysh-d", "-c", "false"]) == 1);
    assert(main(["ysh-d", "-c", "false; echo -n"]) == 0);
    assert(main(["ysh-d", "-c", "false; write -n"]) == 0);
    assert(main(["ysh-d", "-c", "exit 23"]) == 23);
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
