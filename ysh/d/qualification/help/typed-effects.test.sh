## compare_shells: osh

#### help rejects eager typed arguments after evaluating them
shopt --set ysh:upgrade
set +e
func eager() { echo eager; return (42) }
help oils-err-12 (eager())
echo status=$?
## STDOUT:
eager
status=2
## END

#### help rejects lazy typed arguments without evaluating them
shopt --set ysh:upgrade
set +e
func eager() { echo unexpected; return (42) }
help oils-err-12 [eager()]
echo status=$?
## stdout: status=2

#### help rejects literal blocks without executing them
shopt --set ysh:upgrade
set +e
help oils-err-12 { echo unexpected }
echo status=$?
## stdout: status=2

#### typed rejection happens before invalid flag parsing and output
shopt --set ysh:upgrade
set +e
help --invalid (42) > out.txt 2>/dev/null
echo status=$?
test -s out.txt
echo has-output=$?
## STDOUT:
status=2
has-output=1
## END

#### eager arguments run before temporary prefix bindings
shopt --set ysh:upgrade
set +e
func eager() { echo "bound=${HELP_BOUND-unbound}"; return (42) }
HELP_BOUND=temporary help oils-err-12 (eager())
echo "status=$? bound=${HELP_BOUND-unbound}"
## STDOUT:
bound=unbound
status=2 bound=unbound
## END

#### eager output occurs before help redirection is installed
shopt --set ysh:upgrade
set +e
func eager() { echo eager; return (42) }
help oils-err-12 > out.txt 2>/dev/null (eager())
echo status=$?
test -s out.txt
echo has-output=$?
## STDOUT:
eager
status=2
has-output=1
## END

#### eager expression failure prevents help redirect creation
shopt --set ysh:upgrade
try { help oils-err-12 > before.txt (1 / 0) }
if test -e before.txt { echo unexpected-file }
echo "status=$[_error.code]"
## stdout: status=3
