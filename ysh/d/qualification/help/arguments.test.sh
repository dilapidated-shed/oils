## compare_shells: osh

#### help rejects short flags before displaying a topic
help -h oils-err-12 2>/dev/null
echo status=$?
## stdout: status=2

#### help rejects the first character of a short flag cluster
help -dm oils-err-12 2>/dev/null
echo status=$?
## stdout: status=2

#### help rejects long flags
help --help oils-err-12 2>/dev/null
echo status=$?
## stdout: status=2

#### help rejects equal-valued long flags
help --topic=oils-err-12 2>/dev/null
echo status=$?
## stdout: status=2

#### double dash terminates help flag parsing
help -- oils-err-12
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### double dash allows a flag-looking topic but it remains absent
help -- --help 2>/dev/null
echo status=$?
## stdout: status=1

#### lone dash is a topic rather than a flag
help - 2>/dev/null
echo status=$?
## stdout: status=1

#### plus-prefixed words are topics rather than flags
help +x 2>/dev/null
echo status=$?
## stdout: status=1

#### options stop after the first topic
help oils-err-12 -h --help --
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### builtin and command dispatch reach the same help implementation
builtin help oils-err-12 > builtin.txt
command help oils-err-12 > command.txt
cmp builtin.txt command.txt
echo status=$?
cat builtin.txt
## STDOUT:
status=0

    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12

## END
