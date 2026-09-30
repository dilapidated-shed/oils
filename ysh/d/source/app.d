module app;

import std.stdio : stderr, stdin, writeln;
import std.string : join;

import yshd.expr : evaluate;
import yshd.program : ShellExit, executeProgram;
import yshd.state : Memory;
import yshd.value : YshError, repr;

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

            auto mem = new Memory();
            executeProgram(source, mem);
            return 0;
        }

        if (args[1] == "-c") {
            if (args.length < 3) {
                stderr.writeln("ysh-d: -c requires program text");
                return 2;
            }
            auto source = args[2 .. $].join(" ");
            auto mem = new Memory();
            executeProgram(source, mem);
            return 0;
        }

        auto source = args[1 .. $].join(" ");
        writeln(repr(evaluate(source)));
        return 0;
    } catch (ShellExit control) {
        return control.status;
    } catch (YshError error) {
        stderr.writeln("ysh-d: ", error.msg);
        return 3;
    }
}
