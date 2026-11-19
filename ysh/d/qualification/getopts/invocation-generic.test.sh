## compare_shells: osh

#### shared preparation evaluates before temporary environment for shift
shopt --set ysh:upgrade
set -- a b c
func eager() { echo "eager=${BOUND-unbound}"; return (42) }
BOUND=temporary shift (eager())
echo "$?:$#:$1"
## STDOUT:
eager=unbound
0:2:b
## END

#### shift eager argument runs before redirect operand expansion
shopt --set ysh:upgrade
set -- a b
var target = 'before.txt'
func eager() { setglobal target = 'after.txt'; echo eager; return (42) }
shift > "$target" (eager())
if test -e before.txt { echo before-present }
if test -e after.txt { echo after-present }
echo "$?:$#:$1"
## STDOUT:
eager
after-present
0:1:b
## END

#### shift eager failure prevents redirect file creation
shopt --set ysh:upgrade
set -- a b
try { shift > unexpected.txt (1 / 0) }
if test -e unexpected.txt { echo unexpected-file }
echo "$[_error.code]:$#:$1"
## stdout: 3:2:a

#### prefix and proc dispatch evaluate typed values once
shopt --set ysh:upgrade
var calls = 0
func eager() { setglobal calls += 1; return (42) }
proc p (; value) { echo "proc=$value" }
set -- a b c
builtin shift (eager())
command shift (eager())
p (eager())
echo "$calls:$#:$1"
## STDOUT:
proc=42
3:1:c
## END

#### read Place argument evaluates once before redirected input
shopt --set ysh:upgrade
var line = ''
var calls = 0
func place(p) { setglobal calls += 1; echo eager; return (p) }
read --all <<< text (place(&line))
printf '%s:%s' "$calls" "$line"
## STDOUT:
eager
1:text
## END

#### lazy values and literal block stay unevaluated for shift
shopt --set ysh:upgrade
var calls = 0
func eager() { setglobal calls += 1; return (42) }
set -- a b c
shift [eager()]
shift { echo unexpected-block }
echo "$calls:$#:$1"
## stdout: 0:1:c

#### redirected brace keeps inner preparation inside outer redirection
shopt --set ysh:upgrade
set -- a b
func eager() { echo eager; return (42) }
{ shift (eager()); echo inside } > out.txt
echo outside
cat out.txt
## STDOUT:
outside
eager
inside
## END

#### redirected ordinary alias still expands
shopt --set ysh:upgrade
shopt --set expand_aliases
set -- a b
alias G='shift'
G > out.txt
echo "$?:$#:$1"
if test -s out.txt { echo unexpected-output }
## STDOUT:
0:1:b
## END

#### dedicated JSON and pp parsers retain redirected output
shopt --set ysh:upgrade
json write (42) > json.txt
pp test_ ('ok') > pp.txt
cat json.txt pp.txt
## STDOUT:
42
(Str)   "ok"
## END
