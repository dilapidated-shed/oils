module yshd.runtime_objects_test;

version (unittest) {
    import std.stdio : File;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory;
    import yshd.value : ValueKind, YshError;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        executeProgram(`
            func area(self) { return (self.width * self.height) }
            func grow(self, amount) { setvar self.width += amount }
            var methods = Object(null, {area, 'M/grow': grow})
            var rectangle = Obj.new({width: 3, height: 4}, methods)
            var bound = rectangle.area
            assert [type(bound) === 'BoundFunc']
            assert [bound() === 12]
            call rectangle->grow(2)
            assert [bound() === 20]
            var view = first(rectangle)
            setvar view.height = 5
            assert [rectangle.area() === 25]
            var copy = dict(rectangle)
            setvar copy.width = 99
            assert [rectangle.width === 5]
            assert [rest(rectangle) is methods]
            assert [int is int]
            var convert = int
            assert [convert('42') === 42]
            func builtinIdentity() { return (int is convert) }
            assert [builtinIdentity()]
            proc invoke (; self, amount) { setvar self.width += amount }
            var callable = Object(Object(null, {__invoke__: invoke}), {width: 1})
            callable (2)
            assert [callable.width === 3]
            var captured = io->evalExpr(^[rectangle.width])
            assert [captured === 5]
        `, mem);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        executeProgram(`
            var context = {}
            proc emit (; item) { ctx emit items (item) }
            try {
                ctx push (context) {
                    ctx set (label='saved')
                    emit (42)
                    error 'stop' (code=19)
                }
            }
            assert [_error.code === 19]
            assert [context === {label: 'saved', items: [42]}]
            try { ctx set (outside=true) }
            assert [_error.code === 3]
        `, mem);
        assert(mem.contextStack.length == 0);
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        executeProgram(`
            declare -A table=([name]='somebody' [age]=40)
            table[name]+=else
            echo ${table[name]} ${table[age]}
            array=(one 'two words')
            array[4]=last
            append final (array)
            write -- "${array[@]}"
            echo ${#array[@]}
            var fallback = ${1:-empty}
            assert [fallback === 'empty']
        `, mem);
        assert(mem.get("table").kind == ValueKind.bashAssocValue);
        assert(mem.get("array").kind == ValueKind.bashArrayValue);
        output.rewind();
        string actual;
        foreach (line; output.byLineCopy()) actual ~= line ~ "\n";
        assert(actual == "somebodyelse 40\none\ntwo words\nlast\nfinal\n4\n", actual);
        foreach (source; ["var pattern = / d+ /; pattern[invalid]+=1", "var number = 42; number+=1"])
        {
            bool rejected;
            try { executeProgram(source, mem); } catch (YshError error) { rejected = error.status == 1; }
            assert(rejected, source);
        }
        bool rejected;
        try { parseProgram("var weight = ${1:-}; case (weight) { (else) { echo missing }"); }
        catch (YshError error) { rejected = error.status == 2; }
        assert(rejected);
    }
}
