module yshd.capture_io_test;

version (unittest) {
    import std.stdio : File;
    import std.array : replicate;
    import yshd.state : Memory;
    import yshd.process : captureSource;
    import yshd.program : executeProgram, evaluateCommandSubstitution;

    unittest {
        // Each output exceeds pipe capacity. The writer cannot close stdout
        // before writing stderr, so a sequential reader would deadlock.
        import core.sys.posix.unistd : alarm;
        alarm(20);
        scope (exit) alarm(0);
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        auto parentOutput = mem.outputFile;
        auto parentErrors = mem.errorFile;
        mem.lastStatus = 17;
        auto output = "out\0\n".replicate(100_000);
        auto errors = "err\0\n".replicate(100_000);
        auto result = captureSource("", mem, (string source, Memory child) {
            child.outputFile.write(output);
            child.errorFile.write(errors);
            return 42;
        }, true);
        assert(result.stdoutText == output);
        assert(result.stderrText == errors);
        assert(result.status == 42);
        assert(mem.lastStatus == 17);
        assert(mem.outputFile == parentOutput && mem.errorFile == parentErrors);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var result = []
            proc collect (; first, second; named) {
                call result->append(io->evalExpr(first, vars={value: 10}))
                call result->append(io->evalExpr(second, vars={value: 10}))
                call result->append(io->evalExpr(named, vars={value: 10}))
            }
            collect [value + 1, value + 2; named=value + 3]
            assert [result === [11, 12, 13]]
            proc empty () { true }
            empty []
            var command = parseCommand('var first = 42; var second = 43')
            var dictionary = io->eval(command, to_dict=true)
            assert [dictionary === {first: 42, second: 43}]
            try { var broken = parseCommand('echo >') }
            assert [_error === {code: 3, message: 'Syntax error in parseCommand()'}]
        `, mem);
    }

    unittest {
        auto input = File.tmpfile();
        input.write("a\r\nb\0c\nlast");
        input.rewind();
        auto mem = new Memory(input, File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var seen = []
            for index, line in (io.stdin) {
                call seen->append("$index:$line")
                redir <<< nested {
                    for inner in (io.stdin) { assert [inner === 'nested'] }
                }
            }
        `, mem);
        auto values = mem.get("seen").listValue.items;
        assert(values.length == 3);
        assert(values[0].stringValue == "0:a\r");
        assert(values[1].stringValue == "1:b\0c");
        assert(values[2].stringValue == "2:last");
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.initializeArguments("original", ["outer"]);
        auto frame = mem.currentFrame;
        executeProgram(`
            var outer = 'outside'
            var variables = {temporary: 'binding', outer: 'inside'}
            var cmd = ^(
                var first = "$0:$1:$outer:$temporary"
                var hidden_ = 1
                var second = 2
            )
            var result = io->eval(cmd, dollar0='zero', pos_args=['one'], vars=variables, to_dict=true)
            assert [keys(result) === ['first', 'second']]
            assert [result.first === 'zero:one:inside:binding']
            assert [outer === 'outside']
            assert [variables === {temporary: 'binding', outer: 'inside'}]
            assert [ARGV === ['outer']]
            var value = io->evalExpr(^["$0:$1:" ++ outer], dollar0='expr', pos_args=['arg'], vars={outer: 'expression'})
            assert [value === 'expr:arg:expression']
            assert [outer === 'outside']
            call io->eval(^(var persistent = 42), in_captured_frame=true)
            assert [persistent === 42]
            try { call io->eval(^(error stop (code=17)), dollar0='error', pos_args=[], vars={outer: 'error'}) }
            assert [_error.code === 17]
            assert [outer === 'outside']
            echo "$0:$1"
        `, mem);
        assert(mem.currentFrame is frame);
        assert(mem.argumentZero == "original" && mem.shellArguments == ["outer"]);
        assert(mem.findLocal("temporary") is null);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var value = 'global'
            proc make (; out) {
                var value = 'captured'
                setvar out.command = ^(echo $value; echo errors >&2; setglobal value = 'child'; exit 42)
            }
            var out = {}
            make (out)
            var result = io.captureAll(out.command)
            assert [result === {stdout: 'captured' ++ u'\n', stderr: 'errors' ++ u'\n', status: 42}]
            assert [value === 'global']
            try { var ignored = io.captureStdout(out.command) }
            assert [_error.code === 4]
            assert [_error.status === 42]
            assert [_error.message === 'captureStdout(): command failed with status 42']
            var trimmed = io.captureStdout(^(echo first; echo second; echo))
            assert [trimmed === 'first' ++ u'\n' ++ 'second']
            var stop = io.captureAll(^(false; echo unreachable))
            assert [stop.status === 1]
            assert [stop.stdout === '']
            shopt --unset inherit_errexit
            # Expression evaluation enables inherit_errexit even when its
            # enclosing shell disabled it.
            var expression = io.captureAll(^(false; echo unreachable))
            assert [expression.status === 1]
            assert [expression.stdout === '']
        `, mem);
        // Preserve carriage returns while stripping only trailing LF and NUL.
        auto output = evaluateCommandSubstitution("printf 'x\\000\\r\\n\\n'", mem);
        assert(output == "x\r");
    }
}
