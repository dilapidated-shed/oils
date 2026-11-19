## compare_shells: osh

#### getopts ignores eager and lazy typed arguments and literal block
shopt --set ysh:upgrade
func eager(x) { echo "eager=$x"; return (x) }
getopts a opt -a (eager(1); named=eager(2))
echo "$?:$opt:$OPTIND:$OPTARG"
OPTIND=1
getopts a opt -a [eager(3); named=eager(4)]
echo "$?:$opt:$OPTIND:$OPTARG"
OPTIND=1
getopts a opt -a { echo BLOCK }
echo "$?:$opt:$OPTIND:$OPTARG"
OPTIND=1
getopts a opt -a (; ; eager(5))
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
eager=1
eager=2
0:a:2:
0:a:2:
0:a:2:
eager=5
0:a:2:
## END

#### getopts evaluates eager typed arguments before temporary bindings
shopt --set ysh:upgrade
func eager() { echo "eager=${BOUND-unbound}"; return (42) }
BOUND=temporary getopts a opt -a (eager())
echo "$?:$opt:$OPTIND:$OPTARG:${BOUND-unbound}"
## STDOUT:
eager=unbound
0:a:2::unbound
## END

#### getopts evaluates eager typed arguments before command redirection
shopt --set ysh:upgrade
set +e
func eager() { echo eager; return (42) }
getopts a opt -a >out.txt (eager())
echo "$?:$opt:$OPTIND:$OPTARG"
test -s out.txt
echo "redirect-has-output=$?"
## STDOUT:
eager
0:a:2:
redirect-has-output=1
## END

#### getopts eager argument error leaves parser state unchanged
shopt --set ysh:upgrade
OPTARG=seed
opt=seed
trap 'echo "exit:$?:$opt:$OPTIND:$OPTARG"' EXIT
getopts a opt -a (1 / 0)
echo unreachable
## status: 3
## stdout: exit:3:seed:1:seed

#### getopts eager typed evaluation precedes arity failure
shopt --set ysh:upgrade
set +e
func eager() { echo eager; return (42) }
getopts (eager())
echo "status=$? OPTIND=$OPTIND"
## STDOUT:
eager
status=2 OPTIND=1
## END

#### getopts destination name does not make a typed variable immutable
shopt --set ysh:upgrade
var opt = 42
var OPTARG = 99
getopts a: opt -a value
pp test_ (opt)
pp test_ (OPTARG)
## STDOUT:
(Str)   "a"
(Str)   "value"
## END
