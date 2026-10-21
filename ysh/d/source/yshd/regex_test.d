module yshd.regex_test;

version (unittest) {
    import std.stdio : File;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory;
    import yshd.value : Value, YshError, ValueKind;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        executeProgram(`
            var part = 'ab'
            var pattern = / @part <capture d+ as count: int> /
            setvar part = 'changed'
            assert [str(pattern) === 'ab([[:digit:]]+)']
            assert ['ab42' ~ pattern]
            assert [_group('count') === 42]
            assert [_start('count') === 2]
            assert [_end('count') === 4]
            assert ['abc' !~ /d+/]
            assert [_group('count') === 42]
            assert [not ('abc' ~ /d+/)]
            try { call _group(0) }
            assert [_error.code === 3]
            var m = 'ab12 xxab34'.search(pattern, pos=3)
            assert [m.group('count') === 34]
            assert [m.start(0) === 7]
            assert [m.end(0) === 11]
            assert ['xxab12'.leftMatch(pattern) is null]
            assert ['xxab12'.leftMatch(pattern, pos=2).group(0) === 'ab12']
            assert ['ab12'.search('([a-z]+)([0-9]+)').group(2) === '12']
            assert ['a' ~ /<capture 'a'> | <capture 'b'>/]
            assert [_group(2) is null]
            var insensitive = /'a'; i/
            var combined = /@insensitive 'b'; reg_icase/
            assert ['AB' ~ combined]
            assert ['zAB'.search(combined).group(0) === 'AB']
            assert ['foo.cc' ~~ '*.cc']
            assert ['foo.cc' !~~ '*.h']
            var numbers = [1]
            var alias = numbers
            assert [numbers is alias]
            assert [numbers is not [1]]
            assert [floatsEqual(1.5, 1.5)]
        `, mem);
        assert(mem.lastStatus == 0);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        executeProgram(`
            var calls = 0
            func conversion(s) { setglobal calls += 1; return (int(s) + 1) }
            var p = / <capture d+ as n: conversion> /
            func conversion(s) { return (999) }
            var m = '12'.search(p)
            assert [calls === 0]
            assert [m.group('n') === 13]
            assert [calls === 1]
            assert [m.group('n') === 13]
            assert [calls === 2]
            var anchored = /^ d+ '-'/
            assert ['12-34-'.search(anchored, pos=3) is null]
            assert ['12-34-'.leftMatch(anchored, pos=3).group(0) === '34-']
            assert [b'a\n2'.search(/ ^d ; reg_newline /).start(0) === 2]
        `, mem);
        bool invalid;
        try { executeProgram("var bad = / @p ; i /", mem); }
        catch (YshError error) { invalid = error.status == 1; }
        assert(invalid);
        parseProgram("if (false) { var unused = / @unknown <capture d+: missing> / }");
    }
}
