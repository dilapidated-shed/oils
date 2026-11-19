## compare_shells: osh

#### getopts eager argument runs before redirect operand expansion
shopt --set ysh:upgrade
var target = 'before.txt'
func eager() { setglobal target = 'after.txt'; echo eager; return (42) }
getopts a opt -a > "$target" (eager())
if test -e before.txt { echo before-present }
if test -e after.txt { echo after-present }
echo "$?:$opt:$OPTIND:$OPTARG"
## STDOUT:
eager
after-present
0:a:2:
## END

#### getopts eager failure prevents redirect file creation
shopt --set ysh:upgrade
try { getopts a opt -a > before.txt (1 / 0) }
if test -e before.txt { echo unexpected-file }
echo "$[_error.code]:$OPTIND"
## stdout: 3:1

#### getopts eager argument runs before failing redirect open
shopt --set ysh:upgrade
func eager() { echo eager; return (42) }
try { getopts a opt -a > absent-directory/out.txt (eager()) }
echo "$[_error.code]:$OPTIND:${OPTARG-undefined}"
## STDOUT:
eager
1:1:undefined
## END

#### getopts evaluates words before eager arguments
shopt --set ysh:upgrade
var supplied = '-a'
var spec = 'a'
func eager() { setglobal supplied = '-b'; setglobal spec = 'b'; return (42) }
getopts "$spec" opt "$supplied" (eager())
echo "$?:$opt:$OPTIND:$OPTARG:$supplied:$spec"
## stdout: 0:a:2::-b:b

#### getopts observes OPTIND mutation by eager argument once
shopt --set ysh:upgrade
var calls = 0
func eager() { setglobal calls += 1; setglobal OPTIND = '2'; return (42) }
getopts ab opt -a -b > out.txt (eager())
echo "$?:$opt:$OPTIND:$OPTARG:$calls"
## stdout: 0:b:3::1

#### getopts eager function can itself run getopts and share cursor
shopt --set ysh:upgrade
var calls = 0
func eager() {
  setglobal calls += 1
  getopts abc inner -abc
  return (42)
}
getopts abc opt -abc > out.txt (eager())
echo "$?:$opt:$OPTIND:$OPTARG:$calls:$inner"
## stdout: 0:b:1::1:a
