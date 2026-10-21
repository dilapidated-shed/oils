module yshd.case_test;

version (unittest) {
    import std.stdio : File;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory;
    import yshd.value : YshError;

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.errexit = false;
        executeProgram(`
            var hits = []
            var calls = 0
            func next(x) { setglobal calls += 1; return (x) }
            case (next('header.h')) {
                "*.h" { call hits->append('wrong') }
                *.h | $undefined { call hits->append('glob') }
                (next('header.h')) { call hits->append('wrong') }
            }
            assert [hits === ['glob']]
            assert [calls === 1]
            case (next(3)) {
                '3' | $undefined { call hits->append('wrong') }
                (next(1 + 2)) | (undefined) { call hits->append('expr') }
                (else) { call hits->append('wrong') }
            }
            assert [calls === 3]
            assert [hits === ['glob', 'expr']]
            case ('*suffix') { "*"?uffix { call hits->append('mixed') } }
            case ('ax') { [a-c]? { call hits->append('class') } }
            assert [hits === ['glob', 'expr', 'mixed', 'class']]
            case (true) { (else) { call hits->append('else') } (true) { false } }
            assert [hits[-1] === 'else']
            case (0) { (1) { false } }
        `, mem);
        assert(mem.lastStatus == 0);
        executeProgram("false; case ('1') { $? { true } (else) { false } }", mem);
        assert(mem.lastStatus == 0);
        executeProgram("case x in x) false ;;& $(echo y)) true ;; esac", mem);
        assert(mem.lastStatus == 1);
        executeProgram("case (0) { }", mem);
        assert(mem.lastStatus == 0);
        executeProgram("case (0) { (0) { false } }", mem);
        assert(mem.lastStatus == 1);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        executeProgram(`
            var hits = []
            case ('MAIN.PY') { / dot* '.py' ; i / { call hits->append('flag') } }
            case ('foo/foo.py') {
                / '/f' <capture dot* as tail> '.' / {
                    assert [_group(0) === '/foo.']
                    assert [_group(1) === 'oo']
                    assert [_group('tail') === 'oo']
                    assert [_start(1) === 5]
                    assert [_end(1) === 7]
                    call hits->append('capture')
                }
            }
            # POSIX chooses the longest alternative at the leftmost offset.
            case ('xxaa') { / ('a' | 'aa') / { assert [_group(0) === 'aa'] } }
            case ('a') { / <capture 'b'>? 'a' / { assert [_group(1) === null] } }
            case ('!c42-') { / [a-z] <capture digit{2}> / { assert [_group(1) === '42'] } }
            case ('42') { / <capture digit+ : int> / { assert [_group(1) === 42] } }
            func convert(x) { return ('before') }
            func replaced(x) { return ('after') }
            case ('x') {
                / <capture 'x' : convert> / {
                    setvar convert = replaced
                    assert [_group(1) === 'before']
                }
            }
            assert [hits === ['flag', 'capture']]
            case ('none') { / 'absent' / { false } }
        `, mem);
        assert(mem.regexMatch is null);
    }

    unittest {
        auto mem = new Memory(File.tmpfile(), File.tmpfile());
        mem.nounset = true;
        executeProgram(`
            var hits = []
            var subject = 'file.h'
            case $subject in
                ("*.h") call hits->append('wrong') ;;
                *.h|*.cc)
                    case (subject) {
                        *.h { call hits->append('nested-new') }
                    }
                    case x in x) call hits->append('nested-old');; esac
                    ;&
                $undefined) call hits->append('fall-through') ;;&
                *.h) call hits->append('retest') ;;
                *) call hits->append('wrong') ;;
            esac
            assert [hits === ['nested-new', 'nested-old', 'fall-through', 'retest']]
            var captured = $(case (subject) { *.h { echo selected } } | cat)
            assert [captured === 'selected']
            case x in x) true ;; esac && true
            false || case x in x) true ;; esac
            case (1) {
                (1) {
                    case x in
                        x) case y in y) true ;; esac ;;
                    esac
                }
            }
        `, mem);
        assert(mem.lastStatus == 0);
    }

    unittest {
        // Syntax is checked in all arms without runtime name lookup,
        // external commands, matching or side effects.
        parseProgram(`
            case (undefined()) {
                (missing()) | (1 / 0) { exit 99 }
                $missing | "*.h" { no_such_command }
                / @missing <capture digit+ as n: int> ; i / { echo $[_group('n')] }
                (else) { source /no/such/file }
            }
        `);
        foreach (source; [
                "case (0) { (0) { true } (1 +) { false } }",
                "case (0) { (0) { true } (1) { var invalid = } }",
                "case (0) { (else) | (1) { true } }",
                "case (0) { (1) | word { true } }",
                "case (0) { word | (1) { true } }",
                "case (0) { / not_a_class / { true } }",
                "case (0) { / digit+ ; invalid / { true } }",
                "case (0) { / digit{0x2} / { true } }",
                "case (0) { / digit{1_0} / { true } }",
                "case (0) { / <capture digit+ / { true } }"]) {
            bool rejected;
            try { parseProgram(source); }
            catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
    }
}
