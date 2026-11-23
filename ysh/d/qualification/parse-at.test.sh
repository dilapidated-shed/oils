#### only an unquoted leading @ can start a splice
items=(a 'b c')
argv.py user@host @ @42 @items
shopt -s parse_at
argv.py user@host @ @42 '@items' @items
## STDOUT:
['user@host', '@', '@42', '@items']
['user@host', '@', '@42', '@items', 'a', 'b c']
## END

#### disabling parse_at makes a suffixed name literal again
items=(one two)
shopt -s parse_at
argv.py @items
shopt -u parse_at
argv.py @items.suffix
## STDOUT:
['one', 'two']
['@items.suffix']
## END

#### enabled expression and command splices preserve argument boundaries
shopt -s parse_at
argv.py @['one two', 'three'] @(printf '%s\n' 'four five' six)
## stdout: ['one two', 'three', 'four five', 'six']

#### a variable splice must occupy the whole word
shopt -s parse_at
items=(one two)
argv.py @items.suffix
## status: 2
## stdout-json: ""

#### an invalid command splice suffix is rejected before execution
"$SH" -O parse_at -c 'argv.py @(touch ran)suffix' 2>/dev/null
echo status=$?
test ! -e ran
## stdout: status=2

#### adjacent @ and parentheses do not execute with parse_at off
"$SH" +O parse_at -c 'argv.py @(touch ran)' >/dev/null 2>&1
test ! -e ran

#### parse_at_all reserves a bare leading @
shopt -s parse_at parse_at_all
argv.py @
## status: 2
## stdout-json: ""

#### an expression splice requires at least one expression and rejects a trailing comma
"$SH" -O parse_at -c 'argv.py @[]' 2>/dev/null
echo empty=$?
"$SH" -O parse_at -c 'argv.py @[1,]' 2>/dev/null
echo trailing=$?
## STDOUT:
empty=2
trailing=2
## END

#### an attached parenthesis cannot become typed arguments after a splice
shopt -s parse_at
items=(one two)
argv.py @items(null)
## status: 2
## stdout-json: ""
