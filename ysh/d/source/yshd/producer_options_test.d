module yshd.producer_options_test;

// Executable producer-language cases, not claims of complete shell parity.
unittest {
    import std.stdio : File;
    import yshd.program : ShellExit, executeProgram;
    import yshd.state : Memory;
    import yshd.value : YshError;

    struct Case { string source; int status; string output; }
    Case[] cases = [
        Case("set -eu -o pipefail; false; echo wrong", 1, ""),
        Case("set -e; set +e; false; echo after", 0, "after\n"),
        Case("set -e; ! true; echo after", 0, "after\n"),
        Case("set -e; if false { echo wrong } else { echo handled }; echo after", 0, "handled\nafter\n"),
        Case("set -e; if ! false { echo selected }; echo after", 0, "selected\nafter\n"),
        Case("set -e; if true { false; echo wrong }; echo wrong", 1, ""),
        Case("set -e; false | true; echo after", 0, "after\n"),
        Case("set -e -o pipefail; false | true; echo wrong", 1, ""),
        Case("set -e -o pipefail; proc stop { false; echo wrong }; stop | true; echo wrong", 1, ""),
        Case("set -e; proc stop { false; echo wrong }; true | stop; echo wrong", 1, ""),
        Case("set -e; proc stop { false; echo wrong }; stop | true; echo survived", 0, "survived\n"),
        Case("set -o pipefail; false | true; echo status=$?", 0, "status=1\n"),
        Case("set -o pipefail; set +o pipefail; false | true; echo status=$?", 0, "status=0\n"),
        Case("set -e; proc fail { false; echo wrong }; fail; echo wrong", 1, ""),
        Case("proc fail { false }; fail; echo status=$?", 0, "status=1\n"),
        Case("set -e; proc condition { false; echo reached; false }; if condition { echo wrong } else { echo handled }; echo after", 0, "reached\nhandled\nafter\n"),
        Case("set -e; proc enable { set -u }; enable; echo set", 0, "set\n"),
        // SetArgv changes the shell's positional stack. It does not replace
        // the independently mutable ARGV list (core/state.py:Mem.SetArgv).
        Case("set -- 'one word' two; echo $[len(ARGV)] $1 \"$2\"", 0, "0 one word two\n"),
        Case("set +u; echo before${UNBOUND_IL0_CASE}after", 0, "beforeafter\n"),
        Case("setglobal ENV.IL0_CASE = 'environment'; set -u; echo $IL0_CASE", 0, "environment\n"),
        Case("var x = 'hash  path with spaces'; echo \"${x%% *}\"", 0, "hash\n"),
        Case("var x = 'a/b/c'; echo \"${x%/*}\" \"${x%%/*}\" \"${x#*/}\" \"${x##*/}\"", 0, "a/b a b/c c\n"),
        Case("var x = 'αβ'; echo \"${x%?}\" \"${x#?}\"", 0, "α β\n"),
        Case("var x = $(echo captured); echo $x", 0, "captured\n"),
        Case("if '/usr/bin/test' 'one word' = 'one word' { echo quoted }", 0, "quoted\n"),
        Case("echo https://github.com/isomorphisms/lua.git -Wl,--unique=.rodata", 0, "https://github.com/isomorphisms/lua.git -Wl,--unique=.rodata\n"),
        // Numeric-looking shell words do not enter the expression lexer.
        Case("echo 0b29f408 0xnohex 0o89 1__2 12.5 1e-3", 0,
            "0b29f408 0xnohex 0o89 1__2 12.5 1e-3\n"),
    ];
    foreach (item; cases) {
        auto output = File.tmpfile();
        auto errors = File.tmpfile();
        auto mem = new Memory(output, errors);
        // The producer contract uses YSH $[expr], including len(ARGV).
        mem.options.set("parse_ysh_expr_sub", true);
        int status;
        try { executeProgram(item.source, mem); status = mem.lastStatus; }
        catch (ShellExit stopped) { status = stopped.status; }
        output.rewind();
        string actual;
        foreach (line; output.byLineCopy()) actual ~= line ~ "\n";
        assert(status == item.status, item.source);
        assert(actual == item.output, item.source ~ ": " ~ actual);
    }
    foreach (source; ["set -u; echo $UNBOUND_IL0_CASE", "set -u; echo \"$UNBOUND_IL0_CASE\"",
            "set -u; echo ${UNBOUND_IL0_CASE}", "set -o unsupported", "set -x",
            "set -o", "var expression = UNBOUND_IL0_CASE", "var invalid = 0b29",
            "var invalid = 0xnohex", "echo $[0o89]"]) {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        bool rejected;
        try { executeProgram(source, mem); }
        catch (YshError error) { rejected = true; }
        assert(rejected, source);
    }
}

version (linux) unittest {
    import std.conv : to;
    import std.file : readText;
    import std.stdio : File;
    import yshd.program : executeProgram;
    import yshd.state : Memory;

    // Exercise both stream orderings and restoration with actual descriptors.
    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto first = File.tmpfile();
    auto second = File.tmpfile();
    auto mem = new Memory(output, errors);
    auto firstPath = "/proc/self/fd/" ~ to!string(first.fileno());
    auto secondPath = "/proc/self/fd/" ~ to!string(second.fileno());
    executeProgram("proc emit { echo out; echo err >&2 }; emit > '" ~ firstPath ~ "' 2>&1; " ~
        "emit 2>&1 > '" ~ secondPath ~ "'; echo restored; echo error >&2", mem);
    first.rewind(); second.rewind(); output.rewind(); errors.rewind();
    assert(first.readln() == "out\n");
    assert(first.readln() == "err\n");
    assert(second.readln() == "out\n");
    assert(output.readln() == "err\n");
    assert(output.readln() == "restored\n");
    assert(errors.readln() == "error\n");
    assert(output.readln().length == 0 && errors.readln().length == 0);

    // A compound command's condition owns its redirects, not its body.
    executeProgram("if alias missing >/dev/null 2>&1 { echo wrong } else { echo status=$? }", mem);
    output.rewind();
    assert(output.readln() == "err\n");
    assert(output.readln() == "restored\n");
    assert(output.readln() == "status=1\n");

    // A redirect after the complete conditional applies to the selected body.
    executeProgram("if (true) { echo compound } > '" ~ firstPath ~ "'", mem);
    // Read afresh: the original FILE stream may cache bytes from before the
    // interpreter reopened/truncated the same underlying file.
    assert(readText(firstPath) == "compound\n");
}
