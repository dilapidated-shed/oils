#### word-list completion preserves order and duplicates
compgen -W 'second first first' ''
## STDOUT:
second
first
first
## END

#### prefix selection uses only the first operand
compgen -W 'first second first' -- fi ignored
## STDOUT:
first
first
## END

#### no match returns status one
compgen -W 'first second' third
## status: 1
## stdout-json: ""

#### add prefix and suffix after selecting matches
compgen -WPS 'first second' '[' ']' fi
## stdout: [first]

#### the final word-list flag wins
compgen -W 'old list' +W 'new list' ne
## stdout: new

#### plugin word keeps literal quotes
compgen -W '"first second"'
## STDOUT:
"first
second"
## END

#### invalid plugin syntax is caught before substitution can run
compgen -W '$(echo executed > compgen-sentinel) ${'
echo status=$?
test -e compgen-sentinel
echo sentinel=$?
## STDOUT:
status=2
sentinel=1
## END

#### disabled output processing options do not change literal matches
compgen -o filenames -o nospace -W 'first second' s
## stdout: second

#### invalid flag and missing word list report usage
compgen -q
echo invalid=$?
compgen -W
echo missing=$?
compgen
echo no-actions=$?
## STDOUT:
invalid=2
missing=2
no-actions=2
## END

#### empty IFS prevents splitting
IFS=''
compgen -W 'first second' f
## stdout: first second

#### active IFS splits words after expansion and honors escapes
IFS=':%'
data='first:second\:second%third fourth'
compgen -W '$data'
## STDOUT:
first
second:second
third fourth
## END

#### OSH plugin words evaluate backtick substitutions
compgen -W '`printf "%s %s" first second`' s
## stdout: second

#### strict plugin parsing honors shell options
shopt --set no_parse_backticks no_parse_backslash no_parse_dollar
compgen -W '`echo forbidden`'
echo backtick=$?
compgen -W 'first\:second'
echo escape=$?
compgen -W 'first$'
echo dollar=$?
compgen -W 'first\$'
## STDOUT:
backtick=2
escape=2
dollar=2
first$
## END

#### a failed command substitution reports completion failure
shopt --set command_sub_errexit
compgen -W '$(exit 7)'
echo status=$?
## stdout: status=1
