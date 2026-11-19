## compare_shells: osh

#### eager typed values run before prefix assignment RHS evaluation
shopt --set ysh:upgrade
var value = 'before'
func eager() { setglobal value = 'after'; echo eager; return (42) }
proc p (; ignored) { echo "BOUND=$[ENV.BOUND]" }
BOUND=$value p (eager())
echo "value=$value"
## STDOUT:
eager
BOUND=after
value=after
## END
