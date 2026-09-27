module app;

import std.stdio : stderr, writeln;
import std.string : join;

import yshd.expr : evaluate;
import yshd.value : YshError, repr;

int main(string[] args) {
    if (args.length < 2) {
        stderr.writeln("usage: ysh-d EXPRESSION");
        return 2;
    }

    auto source = args[1 .. $].join(" ");
    try {
        writeln(repr(evaluate(source)));
        return 0;
    } catch (YshError error) {
        stderr.writeln("ysh-d: ", error.msg);
        return 3;
    }
}
