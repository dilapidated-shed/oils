module yshd.process_test;

version (Posix) unittest {
    import std.file : getcwd;
    import std.stdio : File;
    import yshd.program : executeProgram, ShellExit;
    import yshd.state : Memory;
    import yshd.value : Value;

    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    auto directory = getcwd();
    executeProgram(`
        var x = 1
        var items = [1]
        echo $(setglobal x = 99; call items->append(2); cd /; echo captured)
        echo $x $[len(items)]
        proc seven { exit 7 }
        proc four { exit 4 }
        set -o pipefail
        seven | four | true
        echo status=$?
        set +o pipefail
        seven | true
        echo status=$?
        var text = ''
        echo child | read --all
        echo $[_reply]
    `, mem);
    assert(getcwd() == directory);
    assert(mem.get("x").integerValue == 1);
    assert(mem.get("items").listValue.length == 1);
    output.rewind();
    string actual;
    while (!output.eof()) actual ~= output.readln();
    assert(actual == "captured\n1 1\nstatus=4\nstatus=0\nchild\n\n", actual);

    // A staged-file implementation would never reach the consumer.
    executeProgram("while true { echo line } | head -n 1", mem);
    // More output than a typical pipe buffer verifies concurrent draining.
    executeProgram("for i in (0..<50000) { echo x } | read --all", mem);
    assert(mem.get("_reply").stringValue.length == 100000);
    executeProgram("var large = $(for i in (0..<50000) { echo x })", mem);
    assert(mem.get("large").stringValue.length == 99999);
    // Expression context propagates command-substitution failures even when
    // the surrounding OSH shell has errexit disabled. Failed declarations do
    // not bind a partial value. Ordinary OSH words can still retain output.
    bool failedDeclaration;
    try { executeProgram("var before_exit = $(echo preserved; exit 23)", mem); }
    catch (ShellExit control) { failedDeclaration = control.status == 23; }
    assert(failedDeclaration && mem.getCell("before_exit") is null);
    executeProgram("echo $(echo preserved; exit 23)", mem);
    bool exited;
    try { executeProgram("true | exit 23; echo wrong", mem); }
    catch (ShellExit control) { exited = control.status == 23; }
    assert(exited);
}

version (linux) unittest {
    import std.algorithm : startsWith;
    import std.file : copy, getAttributes, setAttributes, mkdir, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.stdio : File;
    import std.conv : to;
    import core.sys.posix.unistd : getpid;
    import yshd.process : runExternal;
    import yshd.state : Memory;
    import yshd.value : Value;

    auto directory = buildPath(tempDir(), "ysh-d-path-" ~ to!string(getpid()));
    mkdir(directory);
    scope (exit) rmdirRecurse(directory);
    copy("/usr/bin/printf", buildPath(directory, "shell-path-command"));
    setAttributes(buildPath(directory, "shell-path-command"), getAttributes("/usr/bin/printf"));
    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    auto env = mem.get("ENV").dictValue;
    env.set("PATH", Value.str(directory));
    env.erase("HOME");
    assert(runExternal(["shell-path-command", "from-shell-path\\n"], mem) == 0);
    assert(runExternal(["/usr/bin/env"], mem) == 0);
    assert(runExternal(["missing-ysh-d-test-command"], mem) == 127);
    output.rewind();
    assert(output.readln() == "from-shell-path\n");
    while (!output.eof()) assert(!output.readln().startsWith("HOME="));
}
