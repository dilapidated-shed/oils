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
