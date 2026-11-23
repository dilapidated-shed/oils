#### shopt changes take effect at the next logical line
items=(a 'b c')
shopt -s parse_at; argv.py @items
argv.py @items
shopt -u parse_at; argv.py @items
argv.py @items
## STDOUT:
['@items']
['a', 'b c']
['a', 'b c']
['@items']
## END

#### pipeline stages and continuations inherit the logical-line splice mode
items=(a 'b c')
shopt -s parse_at
shopt -u parse_at; argv.py @items | cat
shopt -s parse_at &&
  argv.py @items | cat
argv.py @items
## STDOUT:
['a', 'b c']
['@items']
['a', 'b c']
## END

#### redirect operands inherit the same mode as the command
items=(a 'b c')
path=(expanded.out)
shopt -s parse_at; argv.py @items > @path
argv.py @items > @path
cat '@path' expanded.out
## STDOUT:
['@items']
['a', 'b c']
## END

#### source and eval sample live options for their own text
printf '%s\n' 'argv.py @items' > words.sh
items=(a 'b c')
shopt -s parse_at; source words.sh; eval 'argv.py @items'; argv.py @items
argv.py @items
## STDOUT:
['a', 'b c']
['a', 'b c']
['@items']
['a', 'b c']
## END

#### a shell function retains the splice mode used for its definition
items=(a 'b c')
literal() { argv.py @items; }
shopt -s parse_at
expanded() { argv.py @items; }
literal
shopt -u parse_at
expanded
## STDOUT:
['@items']
['a', 'b c']
## END

#### a scoped option change does not reparse its already-read block
shopt -s parse_at parse_brace
items=(a 'b c')
shopt -u parse_at { argv.py @items }
shopt -u parse_at
shopt -s parse_at { argv.py @items }
## STDOUT:
['a', 'b c']
['@items']
## END

#### a compound command and its nested substitutions keep their parse mode
items=(a 'b c')
shopt -s parse_at; { argv.py @items
  printf 'sub:%s\n' "$(argv.py @items)"
}
argv.py @items
## STDOUT:
['@items']
sub:['@items']
['a', 'b c']
## END

#### invalid splice suffixes stop before any argument substitution executes
"$SH" -O parse_at -c 'items=(x); argv.py $(touch early-name) @items.suffix' 2>/dev/null
echo name=$?
"$SH" -O parse_at -c 'argv.py $(touch early-expr) @[1,2]suffix' 2>/dev/null
echo expression=$?
"$SH" -O parse_at -c 'argv.py $(touch early-command) @(touch nested)suffix' 2>/dev/null
echo command=$?
test ! -e early-name && test ! -e early-expr && test ! -e early-command && test ! -e nested
## STDOUT:
name=2
expression=2
command=2
## END

#### brace-if lookahead leaves the following logical line a fresh parse mode
shopt -s parse_brace
items=(a 'b c')
if true { shopt -s parse_at }
argv.py @items
## stdout: ['a', 'b c']

#### invalid splice stops an earlier substitution and redirect effects
"$SH" -O parse_at -c 'items=(x); argv.py $(touch earlier) @items.suffix > output' 2>/dev/null
echo status=$?
test ! -e earlier && test ! -e output
## stdout: status=2
