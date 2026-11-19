## compare_shells: osh

#### ENV PATH controls lookup in YSH ahead of shell PATH
/bin/mkdir -p one two
printf '#!/bin/sh\necho one\n' > one/cachecmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
/bin/chmod +x one/cachecmd two/cachecmd
shopt --set ysh:upgrade
PATH=two
setglobal ENV.PATH = 'one'
hash -r
hash cachecmd
cachecmd
hash
## STDOUT:
one
one/cachecmd
## END

#### nonstring ENV PATH supplies no directories but slash names still work
shopt --set ysh:upgrade
set +e
setglobal ENV.PATH = null
hash -r
hash __hash_missing__ 2>/dev/null
echo missing=$?
hash /bin/echo
echo slash=$?
hash
## STDOUT:
missing=1
slash=0
/bin/echo
## END

#### empty ENV PATH searches current directory
printf '#!/bin/sh\necho here\n' > cachecmd
/bin/chmod +x cachecmd
shopt --set ysh:upgrade
setglobal ENV.PATH = ''
hash -r
hash cachecmd
hash
cachecmd
## STDOUT:
cachecmd
here
## END

#### ENV PATH replacement preserves cached resolution until reset
/bin/mkdir -p one two
printf '#!/bin/sh\necho one\n' > one/cachecmd
printf '#!/bin/sh\necho two\n' > two/cachecmd
/bin/chmod +x one/cachecmd two/cachecmd
shopt --set ysh:upgrade
setglobal ENV.PATH = 'one'
hash -r
hash cachecmd
setglobal ENV.PATH = 'two'
cachecmd
hash -r
cachecmd
## STDOUT:
one
two
## END

#### shvar PATH clears cache even after restoring variable scope
shopt --set ysh:upgrade
hash /bin/echo
shvar PATH=/nonexistent { hash }
echo after
hash
## stdout: after

#### shvar invalid later operand still clears cache before entering block
shopt --set ysh:upgrade
set +e
hash /bin/echo
shvar PATH=/nonexistent invalid { echo unexpected } 2>/dev/null
echo status=$?
hash
## stdout: status=2

#### command p bypasses cache and does not populate it
/bin/mkdir -p bin
printf '#!/bin/sh\necho fake\n' > bin/cat
printf 'default\n' > input
/bin/chmod +x bin/cat
PATH=bin
hash -r
hash cat
command -p cat input
hash
hash -r
command -p cat input
echo cache-begin
hash
echo cache-end
## STDOUT:
default
bin/cat
default
cache-begin
cache-end
## END

#### pipeline final command shares cache but background child does not
/bin/mkdir -p bin
printf '#!/bin/sh\necho a\n' > bin/acmd
printf '#!/bin/sh\necho b\n' > bin/bcmd
/bin/chmod +x bin/acmd bin/bcmd
PATH=bin
hash -r
acmd | bcmd
hash
hash -r
acmd >/dev/null &
wait
echo cache-begin
hash
echo cache-end
## STDOUT:
b
bin/bcmd
cache-begin
cache-end
## END

#### nonstring shell PATH is not coerced for command lookup
PATH=(/bin /usr/bin)
hash -r
hash echo 2>/dev/null
echo status=$?
hash
## stdout: status=1
