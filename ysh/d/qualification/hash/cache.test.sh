## compare_shells: osh

#### empty cache and repeated reset are successful
hash
echo status=$?
hash -r
hash -rr
hash --
echo status=$?
## STDOUT:
status=0
status=0
## END

#### hash stores successful operands once and prints sorted path values
/bin/mkdir -p z a
printf '#!/bin/sh\necho z\n' > z/zcmd
printf '#!/bin/sh\necho a\n' > a/acmd
/bin/chmod +x z/zcmd a/acmd
PATH=z:a
hash -r
hash zcmd acmd zcmd
echo status=$?
hash
## STDOUT:
status=0
a/acmd
z/zcmd
## END

#### missing operands do not stop later successful insertions
/bin/mkdir -p bin
printf '#!/bin/sh\necho yes\n' > bin/found
/bin/chmod +x bin/found
PATH=bin
hash -r
hash __missing_one__ found __missing_two__ 2>/dev/null
echo status=$?
hash
## STDOUT:
status=1
bin/found
## END

#### command execution fills the same cache read by hash
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
cachecmd
hash
## STDOUT:
run
bin/cachecmd
## END

#### hash population pins ordinary execution until reset
/bin/mkdir -p one two
printf '#!/bin/sh\necho one\n' > one/cachecmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
/bin/chmod +x one/cachecmd two/cachecmd
PATH=one
hash -r
hash cachecmd
PATH=two
cachecmd
hash
hash -r
cachecmd
hash
## STDOUT:
one
one/cachecmd
two
two/cachecmd
## END

#### execution population pins hash lookup after PATH replacement
/bin/mkdir -p one two
printf '#!/bin/sh\necho one\n' > one/cachecmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
/bin/chmod +x one/cachecmd two/cachecmd
PATH=one
hash -r
cachecmd
PATH=two
hash cachecmd
hash
## STDOUT:
one
one/cachecmd
## END

#### deleted cached path remains visible and hash reports success
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
hash cachecmd
/bin/rm bin/cachecmd
hash cachecmd
echo hash-status=$?
cachecmd 2>/dev/null
echo run-status=$?
hash cachecmd
echo after-run-status=$?
## STDOUT:
hash-status=0
run-status=127
after-run-status=0
## END

#### chmod does not invalidate cached hash but execution returns permission denied
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
hash cachecmd
/bin/chmod -x bin/cachecmd
hash cachecmd
echo hash-status=$?
cachecmd 2>/dev/null
echo run-status=$?
hash -r
hash cachecmd 2>/dev/null
echo reset-status=$?
## STDOUT:
hash-status=0
run-status=126
reset-status=1
## END

#### failed lookup is not negatively cached
/bin/mkdir -p bin
PATH=bin
hash -r
hash cachecmd 2>/dev/null
echo first=$?
printf '#!/bin/sh\necho created\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
hash cachecmd
echo second=$?
cachecmd
## STDOUT:
first=1
second=0
created
## END

#### slash operands cache existing nonexecutable files and directories
/bin/mkdir -p directory
printf text > plain
hash -r
hash ./plain ./directory ./absent 2>/dev/null
echo status=$?
hash
## STDOUT:
status=1
./directory
./plain
## END

#### bare operands skip nonexecutable files and directories
/bin/mkdir -p one/cachecmd two
printf text > one/plaincmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
printf '#!/bin/sh\necho plain\n' > two/plaincmd
/bin/chmod +x two/cachecmd two/plaincmd
PATH=one:two
hash -r
hash cachecmd plaincmd
hash
## STDOUT:
two/cachecmd
two/plaincmd
## END

#### relative cached paths remain relative after changing directory
/bin/mkdir -p one/bin two/bin
printf '#!/bin/sh\necho one\n' > one/bin/cachecmd
printf '#!/bin/sh\necho two\n' > two/bin/cachecmd
/bin/chmod +x one/bin/cachecmd two/bin/cachecmd
PATH=bin
hash -r
cd one
hash cachecmd
cd ../two
cachecmd
hash
## STDOUT:
two
bin/cachecmd
## END

#### empty PATH searches current directory
printf '#!/bin/sh\necho here\n' > cachecmd
/bin/chmod +x cachecmd
PATH=
hash -r
hash cachecmd
hash
cachecmd
## STDOUT:
cachecmd
here
## END

#### unset PATH supplies no search directories
printf '#!/bin/sh\necho here\n' > cachecmd
/bin/chmod +x cachecmd
unset PATH
hash -r
hash cachecmd 2>/dev/null
echo hash=$?
cachecmd 2>/dev/null
echo run=$?
## STDOUT:
hash=1
run=127
## END

#### empty PATH segment preserves a bare relative cache value
/bin/mkdir -p absent
printf '#!/bin/sh\necho here\n' > cachecmd
/bin/chmod +x cachecmd
PATH=absent:
hash -r
hash cachecmd
hash
## stdout: cachecmd

#### subshell reset and insertion do not modify parent cache
/bin/mkdir -p one two
printf '#!/bin/sh\necho one\n' > one/cachecmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
/bin/chmod +x one/cachecmd two/cachecmd
PATH=one
hash -r
hash cachecmd
( PATH=two; hash -r; hash cachecmd; hash )
hash
## STDOUT:
two/cachecmd
one/cachecmd
## END

#### function hash effects persist in calling shell
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
populate() { hash cachecmd; }
populate
hash
clear() { hash -r; }
clear
hash
## stdout: bin/cachecmd

#### command substitution cache effects do not modify parent
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
result=$(hash cachecmd; hash)
echo "child=$result"
echo parent-begin
hash
echo parent-end
## STDOUT:
child=bin/cachecmd
parent-begin
parent-end
## END

#### temporary PATH insertion persists after variable restoration
/bin/mkdir -p one two
printf '#!/bin/sh\necho one\n' > one/cachecmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
/bin/chmod +x one/cachecmd two/cachecmd
PATH=one
hash -r
PATH=two hash cachecmd
echo "PATH=$PATH"
cachecmd
hash
## STDOUT:
PATH=one
two
two/cachecmd
## END

#### exec resolves from the populated shared cache
/bin/mkdir -p one two
printf '#!/bin/sh\necho one\n' > one/cachecmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
/bin/chmod +x one/cachecmd two/cachecmd
PATH=one
hash -r
hash cachecmd
PATH=two
exec cachecmd
echo unreachable
## stdout: one

#### reflection searches current PATH without altering cached execution
/bin/mkdir -p one two
printf '#!/bin/sh\necho one\n' > one/cachecmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
/bin/chmod +x one/cachecmd two/cachecmd
PATH=one
hash -r
hash cachecmd
PATH=two
command -v cachecmd
type -P cachecmd
hash
cachecmd
## STDOUT:
two/cachecmd
two/cachecmd
one/cachecmd
one
## END

#### duplicate values are retained for different cache keys
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
hash cachecmd bin/cachecmd
hash
## STDOUT:
bin/cachecmd
bin/cachecmd
## END
