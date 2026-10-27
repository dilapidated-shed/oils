module yshd.reflection_test;

version (unittest) {
    import std.stdio : File;
    import yshd.state : Memory;
    import yshd.program : executeProgram;
    import yshd.value : ValueKind;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var saved = null
            proc make-frame {
                var value = 41
                setglobal saved = vm.getFrame(-1)
            }
            make-frame
            var before = dict(saved)
            call io->evalInFrame(^(setvar value += 1; var added = 'inside'), saved)
            var after = dict(saved)
            assert [before.value === 41]
            assert [after.value === 42]
            assert [after.added === 'inside']
            assert [keys(after) === ['__E__', 'ARGV', 'value', 'added']]
            assert [dict(after.__E__).saved is saved]

            var local = 'caller'
            var result = io->evalToDict(^(var local = 'temporary'; var hidden_ = 42))
            assert [result === {local: 'temporary'}]
            assert [local === 'caller']
        `, mem);
        assert(mem.lastStatus == 0);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        executeProgram(`
            var root = vm.getFrame(0)
            var marker = 'before'
            try { call io->evalInFrame(^(setvar marker = 'changed'; error stop (code=9)), root) }
            assert [_error.code === 9]
            assert [marker === 'changed']
            assert [keys(dict(vm.getFrame(-1))) === keys(dict(root))]
            try { call vm.getFrame(99999999999999999) }
            assert [_error.code === 3]
            try { call io->evalInFrame(^(echo unexpected), {}) }
            assert [_error.code === 3]
            try { call io->evalToDict(42) }
            assert [_error.code === 3]
            try { call io->evalToDict(^(true), in_captured_frame='yes') }
            assert [_error.code === 3]
        `, mem);
        assert(mem.currentFrame is mem.globalFrame);
        assert(mem.lastStatus == 0);
    }
}
