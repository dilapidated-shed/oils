module yshd.closure_test;

version (unittest) {
    import std.stdio : File;
    import yshd.expr : evaluate, YshExpression;
    import yshd.program : executeProgram, parseProgram, YshCommand;
    import yshd.state : Memory;
    import yshd.value : ValueKind, YshError;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        executeProgram(`
            var base = 4
            proc bind (first='word', ...words; a=base, ...typed; n=7, ...named; block=null) {
                assert [first === 'word']
                assert [a === 4]
                assert [typed === [5, 6]]
                assert [n === 8]
                assert [named === {extra: 9}]
                assert [block is null]
            }
            setvar base = 99
            bind (4, ...[5, 6]; ...{n: 8, extra: 9})
            proc blockType (;;; block) { assert [type(block) === 'Command'] }
            blockType { echo deferred }
            blockType (;; ^(echo deferred))
        `, mem);
        auto output = mem.outputFile;
        output.rewind();
        assert(output.readln() == "");
        foreach (source; ["proc p (;;;) {}", "proc p (; x, x) {}", "proc p (;;; ...blocks) {}",
                "proc p (;;; a, b) {}", "proc p (x Int) {}", "proc p (; x List[]) {}"])
        {
            // An empty block parameter group is valid; the others are not.
            if (source == "proc p (;;;) {}") { parseProgram(source); continue; }
            bool rejected;
            try { parseProgram(source); } catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
        foreach (source; ["proc missing (; x) {}; missing", "proc extra () {}; extra (42)",
                "proc wrongDefault (x=42) {}", "proc mutable (; x=[]) {}"])
        {
            bool rejected;
            try { executeProgram(source, mem); } catch (YshError error) { rejected = error.status == 3; }
            assert(rejected, source);
        }
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        executeProgram(`
            func capture() {
                var local = 'saved'
                return ({expression: ^[local ++ '!'], command: ^(echo $local)})
            }
            var saved = capture()
        `, mem);
        auto saved = mem.get("saved").dictValue;
        auto expression = cast(YshExpression)saved.find("expression").callableValue;
        assert(expression.eval(mem).stringValue == "saved!");
        auto command = cast(YshCommand)saved.find("command").callableValue;
        assert(command.eval(mem) == 0);
        output.rewind();
        assert(output.readln() == "saved\n");
        assert(mem.getCell("local") is null);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.initializeArguments("original", ["argument"]);
        executeProgram(`
            var name = 'original'
            assert ['[ab]' === 'ab'.replace(/ <capture dot+ as name> /, ^"[$name]")]
            assert [name === 'original']
            assert ['a-b' === 'a b'.replace(' ', '-')]
            assert ['newab' === 'ab'.replace('', 'new', count=1)]
            assert ['nanan' === 'aa'.replace('', 'n')]
            assert ['ab' === 'ab'.replace(/ dot /, ^[missing], count=0)]
            try { = '123'.replace(/ <capture d+ as name> /, ^[42]) }
            assert [_error.code === 3]
            assert [name === 'original']
        `, mem);
        assert(mem.argumentZero == "original");
        assert(mem.shellArguments == ["argument"]);
        assert(evaluate(`'x'.replace('x', ^"$0:$1")`, mem).stringValue == "x:argument");
    }
}
