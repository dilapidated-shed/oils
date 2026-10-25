module yshd.arith_test;

version (unittest) {
    import std.exception : assertThrown;
    import std.stdio : File;
    import yshd.arith : evaluateShellArithmetic;
    import yshd.expr : ParseError;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory;
    import yshd.value : Value, FatalRuntimeError;
}

unittest {
    auto mem = new Memory();
    // Shell precedence is intentionally different from YSH's power operator.
    assert(evaluateShellArithmetic("-3**2 + 2**3**2", mem) == 521);
    assert(evaluateShellArithmetic("-7/3", mem) == -2);
    assert(evaluateShellArithmetic("-7%3", mem) == -1);
    assert(evaluateShellArithmetic("-7>>1", mem) == -4);
    assert(evaluateShellArithmetic("(1<<80) + 64#_ + 16#ff", mem) ==
        evaluateShellArithmetic("2**80 + 318", mem));
    assert(evaluateShellArithmetic("0 && 1/0", mem) == 0);
    assert(evaluateShellArithmetic("1 || 1/0", mem) == 1);
    assert(evaluateShellArithmetic("1 ? 9 : 1/0", mem) == 9);
    assert(evaluateShellArithmetic("0 ? 1/0 : 7", mem) == 7);
    assertThrown!FatalRuntimeError(evaluateShellArithmetic("1/0", mem));
    assertThrown!ParseError(evaluateShellArithmetic("1 ? 9 : (2+)", mem));
    assertThrown!ParseError(evaluateShellArithmetic("1+2.3", mem));
    assert(evaluateShellArithmetic("missing + 1", mem) == 1);
    mem.options.set("strict_arith", true);
    assertThrown!FatalRuntimeError(evaluateShellArithmetic("missing + 1", mem));
    assertThrown!FatalRuntimeError(evaluateShellArithmetic("2#2", mem));
    mem.options.set("strict_arith", false);
    mem.nounset = true;
    assertThrown!FatalRuntimeError(evaluateShellArithmetic("missing + 1", mem));
    mem.nounset = false;
    mem.declareLocal("fixed", Value.str("2"), true);
    assertThrown!FatalRuntimeError(evaluateShellArithmetic("fixed++", mem));
    assert(mem.get("fixed").stringValue == "2");
    assertThrown!FatalRuntimeError(evaluateShellArithmetic("fixed+=(side_effect=3)", mem));
    assert(mem.get("side_effect").stringValue == "3");
    mem.setShellVar("index_effect", Value.str("0"));
    assert(evaluateShellArithmetic("missing[index_effect++]", mem) == 0);
    assert(mem.get("index_effect").stringValue == "0");
    import yshd.value : YshDict;
    mem.setShellVar("array", Value.shellArray(new YshDict()));
    mem.nounset = true;
    // The reference's nounset check applies to the array name. Missing
    // elements still coerce to zero unless strict_arith is enabled.
    assert(evaluateShellArithmetic("array[2]++", mem) == 0);
}

unittest {
    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    executeProgram(`
        a=(10 20); i=0
        ((a[i++] += i))
        echo ${a[0]} ${a[1]} $i
        sum=0
        for ((i=0; i<5; ++i)); do
            if ((i==2)); then continue; fi
            ((sum += i))
        done
        echo sum=$sum
        echo $((0 ? $(echo wrong) : 7))
        echo "$((n=5)) $n"
        s='abcd'
        echo ${s:0<1?2:0:1} ${s: -2:1}
    `, mem);
    output.rewind();
    assert(output.readln() == "11 20 1\n");
    assert(output.readln() == "sum=8\n");
    assert(output.readln() == "7\n");
    assert(output.readln() == "5 5\n");
    assert(output.readln() == "c c\n");
    assert(!output.readln().length);
}

unittest {
    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    mem.setShellVar("code", Value.str("$(echo 7)+0"));
    assertThrown!FatalRuntimeError(evaluateShellArithmetic("code+1", mem));
    assert(mem.options.get("_allow_command_sub"));
    mem.options.set("eval_unsafe_arith", true);
    assert(evaluateShellArithmetic("code+1", mem) == 8);
    mem.setShellVar("expression", Value.str("n+2"));
    mem.setShellVar("n", Value.str("3"));
    assert(evaluateShellArithmetic("expression*2", mem) == 10);
}

unittest {
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    auto sentinel = buildPath(tempDir(), "ysh-d-arithmetic-" ~ randomUUID().toString());
    scope (exit) { if (exists(sentinel)) remove(sentinel); }
    // Division, assignment, the infinite loop and nested redirects are all
    // syntax-only. The parser must validate even the unselected expression.
    parseProgram("echo $((1/0)); ((n=7)); echo $((n=$(echo bad > " ~ sentinel ~ "))); for ((;;)) { echo bad }\n");
    assert(!exists(sentinel));
    assertThrown!ParseError(parseProgram("echo $((1 ? 9 : (2+)))"));
    assertThrown!ParseError(parseProgram("a[]=42"));
    assertThrown!ParseError(parseProgram("for ((i=0;i<3)) { echo bad }"));
}
