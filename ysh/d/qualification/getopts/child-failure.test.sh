## compare_shells: osh

#### getopts internal failure in subshell exits one without child EXIT trap
"$SH" -c '
  trap "echo parent-exit" EXIT
  ( trap "echo unexpected-child-exit" EXIT
    getopts abc opt -abc
    getopts a opt -a
    echo unreachable
  )
  echo "subshell=$?"
' 2>/dev/null
## STDOUT:
subshell=1
parent-exit
## END

#### getopts internal failure in command substitution exits one
"$SH" -c '
  trap "echo parent-exit" EXIT
  captured=$(
    trap "echo unexpected-child-exit" EXIT
    getopts abc opt -abc
    getopts a opt -a
    echo unreachable
  )
  echo "capture=$? text=$captured"
' 2>/dev/null
## STDOUT:
capture=1 text=
parent-exit
## END

#### getopts internal failure in pipeline producer exits one
"$SH" -c '
  set -o pipefail
  trap "echo parent-exit" EXIT
  { trap "echo unexpected-child-exit" EXIT
    getopts abc opt -abc
    getopts a opt -a
    echo unreachable
  } | cat
  echo "pipeline=$? statuses=${PIPESTATUS[*]}"
' 2>/dev/null
## STDOUT:
pipeline=1 statuses=1 0
parent-exit
## END

#### getopts internal failure in background job exits one
"$SH" -c '
  trap "echo parent-exit" EXIT
  { trap "echo unexpected-child-exit" EXIT
    getopts abc opt -abc
    getopts a opt -a
    echo unreachable
  } &
  child=$!
  wait "$child"
  echo "job=$?"
' 2>/dev/null
## STDOUT:
job=1
parent-exit
## END
