module yshd.attribute_scope_test;

version (unittest) {
    import std.stdio : File;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory;
    import yshd.value : YshError;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            shopt --unset no_osh_builtins
            split_values() {
                shopt --unset dynamic_scope
                assert [split('a:b::c') === ['a', 'b', '', 'c']]
            }
            caller() { local IFS=:; split_values; }
            caller
            var IFS = ':'
            assert [split('a:b', '') === ['a:b']]
            assert [split('a b', ' ') === ['a', 'b']]
            assert [maybe(null) === []]
            assert [maybe('') === []]
            assert [maybe('value') === ['value']]
            try { false | true }
            assert [_error.code === 1]
            assert [_pipeline_status === [1, 0]]
            proc observe { assert [_pipeline_status === [1, 0]] }
            observe
            var previous = _pipeline_status
            var capturedResult = io.captureAll(^(true | false))
            assert [capturedResult.status === 1]
            assert [_pipeline_status === previous]
            true | true
            try { false }
            assert [_pipeline_status === [0, 0]]
        `, mem);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var outer = 'global'
            proc Dict (; out; ; block) {
                var dictionary = io->eval(block, to_dict=true)
                call out->setValue(dictionary)
            }
            Dict (&record) {
                first = outer
                if (true) { second = 42 }
                for index in ([0, 1]) { repeated = index }
                func deferred() { inside = 43; return (inside) }
            }
            assert [record.first === 'global']
            assert [record.second === 42]
            assert [record.repeated === 1]
            assert [record.deferred() === 43]
            assert [keys(record) === ['first', 'second', 'index', 'repeated', 'deferred']]
            'Dict' (&quoted) { value = 44 }
            assert [quoted.value === 44]
            proc lower (; out; ; block) {
                call out->setValue(io->eval(block, to_dict=true))
            }
            X=ok lower (&prefixed) { value = 45 }
            assert [prefixed.value === 45]
            var command = ^(var explicit = 46)
            var plain = io->eval(command, to_dict=true)
            assert [plain.explicit === 46]
        `, mem);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        foreach (source; [
            "value =1",
            "lower { value = 1 }",
            "UPPER { value = 1 }",
            "var name = 'Dict'; $name { value = 1 }",
            "var name = 'Dict'; \"$name\" { value = 1 }",
            "Dict { lower { value = 1 } }",
            "Dict { var cmd = ^(value = 1) }",
            "Dict { try { value = 1 } }",
            "Dict { shopt -s errexit { value = 1 } }",
        ]) {
            bool rejected;
            try { parseProgram(source, mem.returnMode, mem.options); }
            catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
        parseProgram("'Dict' { value = 1 }", mem.returnMode, mem.options);
        parseProgram("X=ok lower { value = 1 }", mem.returnMode, mem.options);
    }
}
