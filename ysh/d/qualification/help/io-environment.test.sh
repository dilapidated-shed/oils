## compare_shells: osh

#### a failed output sink is a recoverable builtin failure
trap 'echo exit=$?' EXIT
help oils-err-12 > /dev/full 2>/dev/null
echo status=$?
## STDOUT:
status=1
exit=0
## END

#### a closed output descriptor is a recoverable builtin failure
trap 'echo exit=$?' EXIT
help oils-err-12 >&- 2>/dev/null
echo status=$?
## STDOUT:
status=1
exit=0
## END

#### failed missing-topic diagnostic bypasses EXIT traps
trap 'echo unexpected-exit' EXIT
help missing-topic 2>/dev/full
echo unexpected-after
## stdout-json: ""
## status: 2

#### closed missing-topic diagnostic bypasses EXIT traps
trap 'echo unexpected-exit' EXIT
help missing-topic 2>&-
echo unexpected-after
## stdout-json: ""
## status: 2

#### failed help diagnostic in a subshell retains raw status two
trap 'echo parent-exit=$?' EXIT
(help missing-topic 2>/dev/full)
echo child=$?
## STDOUT:
child=2
parent-exit=0
## END

#### failed output is reported through the outer try boundary
shopt --set ysh:upgrade
try { help oils-err-12 > /dev/full }
echo "status=$[_error.code]"
## stdout: status=1

#### failed redirect prevents help output and permits continuation
help oils-err-12 > missing-dir/out.txt 2>/dev/null
echo status=$?
## stdout: status=1

#### prefix bindings do not leak after help
HELP_BOUND=temporary help oils-err-12 > /dev/null
echo "status=$? bound=${HELP_BOUND-unbound}"
## stdout: status=0 bound=unbound

#### changing resource override after startup does not change the cached loader
_OVM_RESOURCE_ROOT=absent-directory help oils-err-12
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### C locale leaves catalog output byte exact
LC_ALL=C help OILS-ERR-12
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### UTF8 locale leaves catalog output byte exact
LC_ALL=C.UTF-8 help OILS-ERR-12
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""
