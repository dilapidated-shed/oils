#### a malformed splice stops earlier commands on its semicolon list
"$SH" -O parse_at -c 'touch earlier; printf "%s\n" @items.suffix' 2>/dev/null
echo status=$?
test ! -e earlier
## stdout: status=2

#### a malformed splice stops an earlier pipeline stage
observed=$("$SH" -O parse_at -c '
  printf "%s\n" stage-started >&3 | printf "%s\n" @items.suffix
' 3>&1 2>/dev/null)
printf 'status=%s observed=<%s>\n' "$?" "$observed"
## stdout: status=2 observed=<>

#### pipeline continuation lines share the same syntax check
observed=$("$SH" -O parse_at -c '
  printf "%s\n" stage-started >&3 |
    printf "%s\n" @items.suffix
' 3>&1 2>/dev/null)
printf 'status=%s observed=<%s>\n' "$?" "$observed"
## stdout: status=2 observed=<>

#### invalid syntax prevents background effects on the same logical line
observed=$("$SH" -O parse_at -c '
  printf "%s\n" background-started & printf "%s\n" @items.suffix; wait
' 2>/dev/null)
printf 'status=%s observed=<%s>\n' "$?" "$observed"
## stdout: status=2 observed=<>

#### a malformed splice in an array initializer prevents earlier substitution
"$SH" -O parse_at -c 'values=($(touch initializer-started) @items.suffix)' 2>/dev/null
echo status=$?
test ! -e initializer-started
## stdout: status=2

#### a malformed splice in local arguments prevents earlier substitution
"$SH" -O parse_at -c 'local prefix="$(touch local-started)" @items.suffix' 2>/dev/null
echo status=$?
test ! -e local-started
## stdout: status=2

#### earlier logical lines still execute before a later line fails to parse
"$SH" -O parse_at -c '
  touch first-line
  touch invalid-line; printf "%s\n" @items.suffix
  touch unreachable-line
' 2>/dev/null
echo status=$?
test -e first-line && test ! -e invalid-line && test ! -e unreachable-line
## stdout: status=2

#### sibling here-documents retain their owning commands during syntax checks
"$SH" -O parse_at -c '
args=(cat)
cat <<FIRST; @args <<SECOND
first
FIRST
second
SECOND
'
## STDOUT:
first
second
## END

#### a malformed splice after a here-document header stops the whole line
observed=$("$SH" -O parse_at -c '
cat <<FIRST; printf "%s\n" @items.suffix <<SECOND
first-should-not-run
FIRST
second-should-not-run
SECOND
' 2>/dev/null)
printf 'status=%s observed=<%s>\n' "$?" "$observed"
## stdout: status=2 observed=<>

#### brace if lookahead leaves the following logical line to its own syntax check
"$SH" -O ysh:upgrade -O parse_at -c '
  if true { touch brace-line }
  touch invalid-line; printf "%s\n" @items.suffix
  touch unreachable-line
' 2>/dev/null
echo status=$?
test -e brace-line && test ! -e invalid-line && test ! -e unreachable-line
## stdout: status=2

#### syntax checks use the splice mode that precedes the logical line
observed=$("$SH" +O parse_at -c '
  shopt -s parse_at; printf "%s\n" @items.suffix
  shopt -u parse_at; touch disabling-line; printf "%s\n" @items.suffix
  touch unreachable-line
' 2>/dev/null)
printf 'status=%s observed=<%s>\n' "$?" "$observed"
test ! -e disabling-line && test ! -e unreachable-line
## stdout: status=2 observed=<@items.suffix>

#### brace if completes before a lexical error on the following line
observed=$("$SH" -O parse_at -O parse_brace -c "
  printf 'first\\n'; if true { printf 'group\\n'; }
  'broken @items
" 2>/dev/null)
printf 'status=%s\n%s\n' "$?" "$observed"
## STDOUT:
status=2
first
group
## END

#### checking a local declaration leaves expansion and binding to execution
"$SH" -O parse_at -c '
  bindings=(answer=good)
  check() { local @bindings; printf "%s\n" "$answer"; }
  check
'
## stdout: good
