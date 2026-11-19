## compare_shells: osh

#### hash rejects eager typed arguments after evaluating them
shopt --set ysh:upgrade
set +e
func eager() { echo eager; return (42) }
hash (eager())
echo status=$?
## STDOUT:
eager
status=2
## END

#### hash rejects lazy typed arguments without evaluating them
shopt --set ysh:upgrade
set +e
func eager() { echo unexpected; return (42) }
hash [eager()]
echo status=$?
## stdout: status=2

#### hash rejects literal blocks without running them
shopt --set ysh:upgrade
set +e
hash { echo unexpected }
echo status=$?
## stdout: status=2

#### typed rejection happens before reset mutates cache
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
hash cachecmd
shopt --set ysh:upgrade
set +e
hash -r (42)
echo status=$?
hash
## STDOUT:
status=2
bin/cachecmd
## END

#### eager arguments run before temporary PATH binding
shopt --set ysh:upgrade
set +e
func eager() { echo "bound=${HASH_BOUND-unbound}"; return (42) }
HASH_BOUND=temporary hash (eager())
echo "status=$? bound=${HASH_BOUND-unbound}"
## STDOUT:
bound=unbound
status=2 bound=unbound
## END

#### eager argument runs before redirected hash diagnostic
shopt --set ysh:upgrade
set +e
func eager() { echo eager; return (42) }
hash > out.txt 2>/dev/null (eager())
echo status=$?
test -s out.txt
echo has-output=$?
## STDOUT:
eager
status=2
has-output=1
## END

#### eager expression failure prevents redirect creation and cache reset
shopt --set ysh:upgrade
try { hash -r > before.txt (1 / 0) }
if test -e before.txt { echo unexpected-file }
echo "status=$[_error.code]"
## stdout: status=3

#### failing redirect prevents cache reset
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
hash cachecmd
hash -r > absent-directory/out.txt 2>/dev/null
echo status=$?
hash
## STDOUT:
status=1
bin/cachecmd
## END
