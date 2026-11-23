#### prefixes and suffixes join the edges of quoted array parts
set -- 'one two' '' tail
argv.py left"$@"right
argv.py "$@$@"
## STDOUT:
['leftone two', '', 'tailright']
['one two', '', 'tailone two', '', 'tail']
## END

#### empty arrays elide only when they are the entire argument
set --
empty=''
argv.py "$@" -"$@"- "$@$empty" "" "$@"
shopt -s simple_word_eval
argv.py "$@" -"$@"- "$@$empty" "" "$@"
## STDOUT:
['--', '', '']
['--', '', '']
## END

#### named array parts preserve spaces and empty elements
items=('one two' '' tail)
argv.py left"${items[@]}"right
## stdout: ['leftone two', '', 'tailright']

#### static operators trigger globbing of the whole evaluated word
shopt -s simple_word_eval
touch bar.txt far.txt other.txt
pattern='[bf]'
argv.py "$pattern"*.txt
argv.py $pattern '*'
## STDOUT:
['bar.txt', 'far.txt']
['[bf]', '*']
## END

#### a static glob joins positional elements with spaces regardless of IFS
shopt -s simple_word_eval
IFS=:
set -- one two
touch 'one two.log'
argv.py "$@"*.log
## stdout: ['one two.log']

#### strict array checking happens before noglob can skip expansion
shopt -s simple_word_eval strict_array
shopt -s noglob
set -- first
argv.py "$@"*.txt
## status: 1
## stdout-json: ""

#### each brace alternative retains its own literal glob operator
shopt -s simple_word_eval
touch a.tag b.tag other.tag
prefix=a
argv.py {$prefix,b}*.tag
## stdout: ['a.tag', 'b.tag']

#### indexed array words can add zero or multiple elements
shopt -s simple_word_eval nullglob
set --
touch first.one first.two
items=(missing* first.* 'first.*' "$@" last)
argv.py "${items[@]}"
## stdout: ['first.one', 'first.two', 'first.*', 'last']

#### braced positional arguments and scalar array compatibility
set -- 'one two' tail
value='three four'
argv.py left"${@}"right "${value[@]}"
## stdout: ['leftone two', 'tailright', 'three four']

#### bracket globs and explicit indices have different initializer rules
shopt -s simple_word_eval
touch a.data b.data
items=([ab].data [4]=*.data [6]= tail)
argv.py "${items[@]}"
## stdout: ['a.data', 'b.data', '*.data', '', 'tail']

#### at signs remain literal with parse_at disabled
items=(@literal)
argv.py "${items[@]}"
## stdout: ['@literal']

#### unexpanded simple globs remove glob escapes
shopt -s simple_word_eval
piece='unique\*'
argv.py "$piece"*.missing
shopt -s noglob
argv.py "$piece"*.missing
## STDOUT:
['unique**.missing']
['unique**.missing']
## END

#### disabled command splices do not execute inside initializers
"$SH" -c 'items=(@(touch ran))' >/dev/null 2>&1
test ! -e ran
