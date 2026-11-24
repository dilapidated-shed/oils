#### expression substitutions keep the mode of their logical line
shopt -s ysh:upgrade
var items = ['one', 'two words']
shopt -u parse_at
shopt -s parse_at; var plain = $(printf '<%s>' @items); var quoted = "q:$(printf '<%s>' @items)"
assert [plain === '<@items>']
assert [quoted === 'q:<@items>']
var next = $(printf '<%s>' @items)
assert [next === '<one><two words>']
shopt -u parse_at; var stillOn = "$(printf '<%s>' @items)"
assert [stillOn === '<one><two words>']
var nextOff = $(printf '<%s>' @items)
assert [nextOff === '<@items>']
## stdout-json: ""

#### both shell word array spellings keep the enclosing parse mode
shopt -s ysh:upgrade
var items = ['one', 'two words']
shopt -u parse_at
shopt -s parse_at; var parenOff = %( @items ); var pipeOff = :| @items |
assert [parenOff === ['@items']]
assert [pipeOff === ['@items']]
shopt -u parse_at; var parenOn = %( @items ); var pipeOn = :| @items |
assert [parenOn === ['one', 'two words']]
assert [pipeOn === ['one', 'two words']]
## stdout-json: ""

#### command literals keep their parse mode through later invocation
shopt -s ysh:upgrade
var items = ['one', 'two words']
shopt -u parse_at
shopt -s parse_at; var literalOff = ^(write @items)
shopt -u parse_at; var literalOn = ^(write @items)
call io->eval(literalOn)
shopt -s parse_at
call io->eval(literalOff)
## STDOUT:
one
two words
@items
## END

#### deferred expressions keep the mode of their nested static source
shopt -s ysh:upgrade
var items = ['one', 'two words']
shopt -u parse_at
var commandExpr = ^[^(write @items)]
var captureExpr = ^[$(printf '<%s>' @items)]
var quoteExpr = ^["q:$(printf '<%s>' @items)"]
var wordsExpr = ^[%( @items )]
shopt -s parse_at
var made = io->evalExpr(commandExpr)
call io->eval(made)
assert [io->evalExpr(captureExpr) === '<@items>']
assert [io->evalExpr(quoteExpr) === 'q:<@items>']
assert [io->evalExpr(wordsExpr) === ['@items']]
## stdout: @items

#### parseCommand reads live options and preserves its result's mode
shopt -s ysh:upgrade
var items = ['one', 'two words']
shopt -u parse_at
var deferred = ^[parseCommand('write @items')]
shopt -s parse_at; var dynamicOn = io->evalExpr(deferred); var staticOff = ^(write @items)
shopt -u parse_at
call io->eval(dynamicOn)
var dynamicOff = parseCommand('write @items.suffix')
shopt -s parse_at
call io->eval(staticOff)
call io->eval(dynamicOff)
try { var malformed = parseCommand('write @items.suffix') }
assert [_error.code === 3]
## STDOUT:
one
two words
@items
@items.suffix
## END

#### command literals also preserve the separate bare at sign restriction
shopt -s ysh:upgrade
shopt -u parse_at_all
var literal = ^(write @)
shopt -s parse_at_all
call io->eval(literal)
try { var malformed = parseCommand('write @') }
assert [_error.code === 3]
## stdout: @

#### parse-only checks use the selected mode in each expression form
for expr in '$(write @items.suffix)' '"$(write @items.suffix)"' '%( @items.suffix )' ':| @items.suffix |' '^(write @items.suffix)'; do
  "$SH" -O ysh:upgrade +O parse_at --ast-format none -n -c "var x = $expr" >/dev/null 2>&1
  echo off=$?
  "$SH" -O ysh:upgrade -O parse_at --ast-format none -n -c "var x = $expr" >/dev/null 2>&1
  echo on=$?
done
## STDOUT:
off=0
on=2
off=0
on=2
off=0
on=2
off=0
on=2
off=0
on=2
## END

#### defaults, typed arguments and mutation use the mode at their source
shopt -s ysh:upgrade
var items = ['one', 'two words']
shopt -u parse_at
shopt -s parse_at; func defaultOff(value=$(printf '<%s>' @items)) { return (value) }
assert [defaultOff() === '<@items>']
shopt -u parse_at; proc defaultOn (; value=$(printf '<%s>' @items)) { write -- $value }
defaultOn
proc show (; value) { write -- $value }
shopt -s parse_at; show ($(printf '<%s>' @items))
var changed = ''
shopt -u parse_at; setvar changed = $(printf '<%s>' @items)
assert [changed === '<one><two words>']
## STDOUT:
<one><two words>
<@items>
## END
