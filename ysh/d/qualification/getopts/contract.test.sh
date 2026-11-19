## compare_shells: osh

#### getopts -- preserves argument and does not latch termination
OPTARG=old
getopts a opt -- -a
echo "$?:$opt:$OPTIND:$OPTARG"
getopts a opt -- -a
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
1:?:2:old
0:a:3:
## END

#### getopts operand terminates and clears silent OPTARG
OPTARG=old
getopts :a opt operand -a
echo "$?:$opt:$OPTIND:$OPTARG"
## stdout: 1:?:1:

#### getopts cursor survives OPTIND reset and changed arguments
getopts abc opt -abc
echo "$?:$opt:$OPTIND:$OPTARG"
OPTIND=1
getopts xyz opt -xyz
echo "$?:$opt:$OPTIND:$OPTARG"
getopts xyz opt -xyz
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
0:a:1:
0:y:1:
0:z:2:
## END

#### getopts validates destination after option argument mutation
getopts a: bad- -a value 2>/dev/null
echo "$?:${opt-}:$OPTIND:$OPTARG"
## stdout: 2::3:value

#### getopts destination OPTIND overwrites numeric cursor
getopts a OPTIND -a
echo "$?:$OPTIND:$OPTARG"
getopts a opt -a 2>/dev/null
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
0:a:
1:?:a:
## END

#### getopts destination OPTARG overwrites option argument
getopts a: OPTARG -a value
echo "$?:$OPTIND:$OPTARG"
## stdout: 0:3:a

#### getopts duplicate specification last occurrence wins
getopts a:a opt -a value
echo "$?:$opt:$OPTIND:$OPTARG"
## stdout: 0:a:2:

#### getopts colon can itself be a valid flag
getopts :: opt -:
echo "$?:$opt:$OPTIND:$OPTARG"
## stdout: 0:::2:

#### getopts missing required option consumes option word
getopts :a: opt -a
echo "$?:$opt:$OPTIND:$OPTARG"
getopts :a: opt -a
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
0:::2:a
1:?:2:
## END

#### getopts argument accepts option terminator and option looking word
getopts a: opt -a -- -a -z
echo "$?:$opt:$OPTIND:$OPTARG"
getopts a: opt -a -- -a -z
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
0:a:3:--
0:a:5:-z
## END

#### getopts unknown option continues a byte cluster
getopts :a opt -xya
echo "$?:$opt:$OPTIND:$OPTARG"
getopts :a opt -xya
echo "$?:$opt:$OPTIND:$OPTARG"
getopts :a opt -xya
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
0:?:1:x
0:?:1:y
0:a:2:
## END

#### getopts OPTIND accepts arbitrary precision decimal and clears on end
OPTIND=184467440737095516160
OPTARG=old
getopts a opt -a
echo "$?:$opt:$OPTIND:$OPTARG"
OPTIND=0001
getopts a opt -a
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
1:?:184467440737095516160:
0:a:2:
## END

#### getopts OPTIND decimal grammar
for OPTIND in ' +01 ' 1L 0x1 1_0 '' ' ' -1 -2 0; do
  getopts a opt -a 2>/dev/null
  echo "$?:$opt:$OPTIND:$OPTARG"
done
## STDOUT:
0:a:2:
1:?:1L:
1:?:0x1:
1:?:1_0:
1:?::
1:?: :
1:?:-1:
1:?:-2:
1:?:0:
## END

#### getopts invalid OPTERR falls back to ordinary diagnostics
OPTERR=invalid
getopts a opt -z 2>/dev/null
echo "$?:$opt:$OPTIND:$OPTARG"
OPTIND=1
OPTERR=0
getopts a opt -z
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
0:?:2:
0:?:2:
## END

#### getopts sees shifted visible positional frame
set -- ignored -a -b value
shift 1
getopts ab: opt
echo "$?:$opt:$OPTIND:$OPTARG:$#"
getopts ab: opt
echo "$?:$opt:$OPTIND:$OPTARG:$#"
## STDOUT:
0:a:2::3
0:b:4:value:3
## END

#### getopts cursor shared across function and caller
getopts abc opt -abc
parse() {
  local OPTIND=1
  getopts xyz opt -xyz
  echo "function:$?:$opt:$OPTIND:$OPTARG"
}
parse
echo "caller:$OPTIND:$opt:$OPTARG"
getopts abc opt -abc
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
function:0:y:1:
caller:1:y:
0:c:2:
## END

#### getopts mutable array destination and OPTARG become strings
declare -a opt=(before)
declare -a OPTARG=(before)
getopts a: opt -a value
echo "$?:$opt:$OPTIND:$OPTARG"
## stdout: 0:a:3:value

#### getopts readonly OPTARG fails after advancing OPTIND
OPTARG=seed
opt=seed
readonly OPTARG
trap 'echo "exit:$?:$opt:$OPTIND:$OPTARG"' EXIT
getopts a opt -a
echo unreachable
## status: 1
## stdout: exit:1:seed:2:seed

#### getopts readonly destination fails after advancing index and argument
opt=seed
readonly opt
trap 'echo "exit:$?:$opt:$OPTIND:$OPTARG"' EXIT
getopts a: opt -a value
echo unreachable
## status: 1
## stdout: exit:1:seed:3:value

#### getopts readonly OPTIND aborts before OPTARG and destination
OPTARG=seed
opt=seed
readonly OPTIND
trap 'echo "exit:$?:$opt:$OPTIND:$OPTARG"' EXIT
getopts a opt -a
echo unreachable
## status: 1
## stdout: exit:1:seed:1:seed

#### getopts missing words leave parser variables untouched
OPTARG=seed
opt=seed
getopts 2>/dev/null
echo "$?:$opt:$OPTIND:$OPTARG"
getopts a 2>/dev/null
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
2:seed:1:seed
2:seed:1:seed
## END

#### getopts invalid name still clears OPTARG at end of arguments
OPTIND=8
OPTARG=seed
getopts a bad- -a 2>/dev/null
echo "$?:$OPTIND:$OPTARG"
## stdout: 2:8:

#### getopts stale cluster cursor out of bounds is fatal
"$SH" -c 'trap "echo unexpected-exit-trap" EXIT; getopts abc opt -abc; getopts abc opt -a; echo unreachable' 2>/dev/null
echo "boundary=$?"
## stdout: boundary=1

#### getopts source and eval share cursor while subshell owns copy
getopts abc opt -abc
cat > parse.grease <<'EOF'
getopts xyz opt -xyz
echo "source:$?:$opt:$OPTIND:$OPTARG"
EOF
. ./parse.grease
eval 'getopts abc opt -abc'
echo "eval:$?:$opt:$OPTIND:$OPTARG"
OPTIND=1
getopts abc opt -abc
( getopts abc opt -abc; echo "subshell:$?:$opt:$OPTIND:$OPTARG" )
getopts abc opt -abc
echo "parent:$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
source:0:y:1:
eval:0:c:2:
subshell:0:b:1:
parent:0:b:1:
## END

#### getopts non ASCII and invalid UTF8 option bytes remain separate
getopts : opt '-é'
printf '%s|%s|' "$?" "$OPTIND"
printf '%s' "$OPTARG" | od -An -tx1
getopts : opt '-é'
printf '%s|%s|' "$?" "$OPTIND"
printf '%s' "$OPTARG" | od -An -tx1
OPTIND=1
getopts : opt $'-\xff'
printf '%s|%s|' "$?" "$OPTIND"
printf '%s' "$OPTARG" | od -An -tx1
## STDOUT:
0|1| c3
0|2| a9
0|2| ff
## END

#### getopts invalid UTF8 OPTIND fails recoverably
OPTIND=$'\xff'
getopts a opt -a 2>/dev/null
printf '%s|%s|' "$?" "$opt"
printf '%s' "$OPTIND" | od -An -tx1
echo "OPTARG=$OPTARG"
## STDOUT:
1|?| ff
OPTARG=
## END

#### getopts silent mode and OPTERR zero do not suppress malformed OPTIND
OPTIND=invalid
OPTERR=0
getopts :a opt -a 2> error.txt
echo "$?:$opt:$OPTIND:$OPTARG"
test -s error.txt
echo "diagnostic=$?"
## STDOUT:
1:?:invalid:
diagnostic=0
## END

#### getopts permits one trailing newline in destination but rejects two
shopt --set ysh:upgrade
set +e
accepted=$'opt\n'
getopts a: "$accepted" -a value
echo "$?:$OPTIND:$OPTARG"
pp test_ (getVar(accepted))
OPTIND=1
rejected=$'opt\n\n'
getopts a: "$rejected" -a next 2>/dev/null
echo "$?:$OPTIND:$OPTARG"
pp test_ (getVar(rejected))
## STDOUT:
0:3:value
(Str)   "a"
2:3:next
(Null)   null
## END
