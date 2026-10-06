## our_shell: ysh
## suite: ysh
## oils_failures_allowed: 0
## compare_shells:

#### Grease keeps aliases available with the full YSH option group
shopt -s ysh:all
alias ll='printf "%s\n" alias-ok'
ll
unalias ll
if alias ll >/dev/null 2>&1 {
  echo status=0
} else {
  echo status=$?
}
## STDOUT:
alias-ok
status=1
## END

#### Readable declarations can opt in through ordinary aliases
shopt -s ysh:all
alias procedure=proc
alias define_function=func
procedure greet { echo procedure-ok }
define_function twice(x) { return (x * 2) }
greet
echo $[twice(21)]
## STDOUT:
procedure-ok
42
## END
