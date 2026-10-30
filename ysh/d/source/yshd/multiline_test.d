module yshd.multiline_test;

version (unittest) {
    import std.stdio : File;
    import yshd.program : executeProgram, parseProgram;
    import yshd.state : Memory, ReturnMode;
    import yshd.options : ShellOptions;
    import yshd.value : YshError;

    private string contents(File output) {
        output.rewind();
        string result;
        while (!output.eof()) result ~= output.readln();
        return result;
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.errexit = false;
        // A deferred block/procedure retains its original lexical mode.
        // A command substitution starts a fresh parser with normal newlines.
        executeProgram(`
var delayed = null
proc remember (;;; body) { setglobal delayed = body }
... remember {
  echo
    block-one
    ;
  echo block-two;
}
;
call io->eval(delayed)
... proc deferred {
  echo
    proc-one
    ;
}
;
deferred
... echo $(echo first

echo second)
  tail
  ;
echo normal-after

        `, mem);
        assert(contents(output) ==
            "block-one\nblock-two\nproc-one\nfirst\nsecond tail\nnormal-after\n");
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        executeProgram(`
            ... echo  # comments do not count as blank lines
                one
                # another comment
                two
                ;
            echo ordinary
            ... { echo piped; echo again; }
              | builtin cat
              ;
            ... false
              || echo recovered
              && [[ 3 -eq 3 ]]
              && echo conditional
              ;
            ... echo before
                $(... echo
                    inside
                    substitution)
                after
                ;
            echo ... literal
        `, mem);
        assert(contents(output) ==
            "one two\nordinary\npiped\nagain\nrecovered\nconditional\nbefore inside substitution after\n... literal\n");
        foreach (source; ["... echo one\n\ntwo;", "... echo one\n \t\ntwo;", "..."]) {
            bool rejected;
            try { parseProgram(source, ReturnMode.shell, new ShellOptions()); }
            catch (YshError error) { rejected = error.status == 2; }
            assert(rejected, source);
        }
        // Parse-only validates continuation syntax without running any word,
        // substitution, branch, procedure or effect.
        parseProgram("... echo\n $(exit 94)\n $undefined\n ;\n... while true { exit 95; }\n;",
            ReturnMode.shell, new ShellOptions());
    }

    unittest {
        auto output = File.tmpfile();
        auto mem = new Memory(output, File.tmpfile());
        mem.options.set("ysh:all", true);
        mem.initializeDirectory();
        executeProgram(`
            ... shopt --unset errexit {
                echo
                    option-body
                    ;
            }
            ;
            ... cd . {
                echo
                    directory-body
                    ;
            }
            ;
            ... forkwait {
                echo
                    child-body
                    ;
            }
            ;
            ... trap --add EXIT {
                echo
                    exit-body
                    ;
            }
            ;
            ... eval 'echo first
echo second'
                ;
        `, mem);
        assert(mem.traps.finish(mem, 0) == 0);
        mem.traps.restore();
        assert(contents(output) ==
            "option-body\ndirectory-body\nchild-body\nfirst\nsecond\nexit-body\n");
    }
}
