## compare_shells: osh

#### error catalog URL uses the source version and exact spacing
help oils-err-12
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### error catalog prefix and anchor are case insensitive
help OiLs-ErR-XYZ
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-xyz\n\n"
## stderr-json: ""

#### error catalog heuristic accepts an empty suffix
help oils-err
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err\n\n"
## stderr-json: ""

#### error catalog heuristic accepts a nonnumber suffix
help oils-error/unknown
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-error/unknown\n\n"
## stderr-json: ""

#### error catalog anchors preserve punctuation and spaces
help 'OILS-ERR-A B?#'
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-a b?#\n\n"
## stderr-json: ""

#### the error catalog prefix is not whitespace trimmed
help ' oils-err-12' 2>/dev/null
## stdout-json: ""
## status: 1

#### ordinary topic lookup is case sensitive
help OILS-USAGE 2>/dev/null
## stdout-json: ""
## status: 1

#### only the first topic operand is displayed
help oils-err-12 oils-err-99 --invalid ''
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### a later valid topic cannot rescue a missing first operand
help missing-topic oils-err-12 2>/dev/null
## stdout-json: ""
## status: 1

#### trailing operands are expanded before they are ignored
help oils-err-12 "$(echo expanded >&2)" > out.txt
echo status=$?
cat out.txt
## STDOUT:
status=0

    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12

## END
## stderr: expanded

#### help does not depend on PATH or a current-directory resource tree
mkdir elsewhere
cd elsewhere
PATH=
help oils-err-12
## stdout-json: "\n    https://oils.pub/release/0.37.0/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""
