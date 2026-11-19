## compare_shells: osh

#### missing command report to full stderr exits before EXIT trap
trap 'echo exit=$?' EXIT
__hash_diagnostic_missing__ 2>/dev/full
echo after=$?
## stdout-json: ""
## status: 2

#### missing command report to closed stderr exits before EXIT trap
trap 'echo exit=$?' EXIT
__hash_diagnostic_missing__ 2>&-
echo after=$?
## stdout-json: ""
## status: 2

#### subshell report to full stderr has raw I/O status two
trap 'echo parent-exit=$?' EXIT
(__hash_diagnostic_missing__ 2>/dev/full)
echo child=$?
hash
## STDOUT:
child=2
parent-exit=0
## END

#### subshell report to closed stderr has raw I/O status two
trap 'echo parent-exit=$?' EXIT
(__hash_diagnostic_missing__ 2>&-)
echo child=$?
hash
## STDOUT:
child=2
parent-exit=0
## END

#### pipeline producer report to full stderr retains stage status
trap 'echo parent-exit=$?' EXIT
__hash_diagnostic_missing__ 2>/dev/full | /bin/cat
echo status=$? parts="${PIPESTATUS[@]}"
hash
## STDOUT:
status=0 parts=2 0
/bin/cat
parent-exit=0
## END

#### pipeline producer report to closed stderr retains stage status
trap 'echo parent-exit=$?' EXIT
__hash_diagnostic_missing__ 2>&- | /bin/cat
echo status=$? parts="${PIPESTATUS[@]}"
hash
## STDOUT:
status=0 parts=2 0
/bin/cat
parent-exit=0
## END

#### command substitution report to full stderr has raw I/O status two
trap 'echo parent-exit=$?' EXIT
x=$(__hash_diagnostic_missing__ 2>/dev/full)
echo child=$? value="$x"
hash
## STDOUT:
child=2 value=
parent-exit=0
## END

#### command substitution report to closed stderr has raw I/O status two
trap 'echo parent-exit=$?' EXIT
x=$(__hash_diagnostic_missing__ 2>&-)
echo child=$? value="$x"
hash
## STDOUT:
child=2 value=
parent-exit=0
## END
