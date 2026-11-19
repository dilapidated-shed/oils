## compare_shells: osh

#### reset rejects extra operands without clearing the cache
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
hash cachecmd
hash -r cachecmd 2>/dev/null
echo status=$?
hash
## STDOUT:
status=2
bin/cachecmd
## END

#### invalid flags reject before clearing the cache
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
hash cachecmd
hash -rx 2>/dev/null
echo status=$?
hash
## STDOUT:
status=2
bin/cachecmd
## END

#### options stop at first operand and remaining dash words are names
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
printf '#!/bin/sh\necho dash\n' > bin/-r
/bin/chmod +x bin/cachecmd bin/-r
PATH=bin
hash -r
hash cachecmd -r
echo status=$?
hash
## STDOUT:
status=0
bin/-r
bin/cachecmd
## END

#### double dash allows a dash option name as an operand
/bin/mkdir -p bin
printf '#!/bin/sh\necho dash\n' > bin/-r
/bin/chmod +x bin/-r
PATH=bin
hash -r
hash -- -r
echo status=$?
hash
## STDOUT:
status=0
bin/-r
## END

#### single dash and plus flag words are ordinary names
/bin/mkdir -p bin
printf '#!/bin/sh\necho dash\n' > bin/-
printf '#!/bin/sh\necho plus\n' > bin/+r
/bin/chmod +x bin/- bin/+r
PATH=bin
hash -r
hash - +r
echo status=$?
hash
## STDOUT:
status=0
bin/+r
bin/-
## END

#### empty name fails without inserting a cache entry
hash '' 2>/dev/null
echo status=$?
hash
## stdout: status=1

#### bare builtin and function names still require executable PATH entries
function only_function { echo function; }
PATH=
hash -r
hash echo only_function 2>/dev/null
echo status=$?
hash
## stdout: status=1

#### reset accepts repeated r and double dash terminator
/bin/mkdir -p bin
printf '#!/bin/sh\necho run\n' > bin/cachecmd
/bin/chmod +x bin/cachecmd
PATH=bin
hash -r
hash cachecmd
hash -rr --
echo status=$?
hash
## stdout: status=0

#### long flag spelling is rejected
hash --reset 2>/dev/null
echo status=$?
## stdout: status=2

#### reset followed by double dash still rejects operands
hash -r -- operand 2>/dev/null
echo status=$?
## stdout: status=2
