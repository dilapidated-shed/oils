## our_shell: osh

#### main help precedes version and does not execute the command string
$SH --help > expected.txt || exit $?
$SH --version --help -c 'echo unexpected > marker.txt' > actual.txt || exit $?
cmp expected.txt actual.txt
test ! -e marker.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### invalid later flag rejects main help before any version or card output
$SH --help --invalid-help-control > actual.txt 2>/dev/null
echo status=$?
test -s actual.txt
echo has-output=$?
## STDOUT:
status=2
has-output=1
## END

#### missing command operand rejects main help before any card output
$SH --help -c > actual.txt 2>/dev/null
echo status=$?
test -s actual.txt
echo has-output=$?
## STDOUT:
status=2
has-output=1
## END

#### main help before double dash ignores following script words
$SH --help > expected.txt || exit $?
$SH --help -- -c --invalid-help-control > actual.txt || exit $?
cmp expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### double dash makes help-looking filename an ordinary source path
printf 'echo source-ran\n' > --help
$SH -- --help
## stdout: source-ran
## stderr-json: ""

#### help and version words after the command string remain positional arguments
$SH -c 'printf "<%s>\n" "$0" "$@"' command-zero --help --version
## STDOUT:
<command-zero>
<--help>
<--version>
## END
## stderr-json: ""

#### main help does not execute the source file operand
printf 'echo unexpected > marker.txt\n' > source.sh
$SH --help > expected.txt || exit $?
$SH --help source.sh > actual.txt || exit $?
cmp expected.txt actual.txt
test ! -e marker.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### original buffered main help teardown keeps zero status for full and closed output
$SH --help > /dev/full 2>/dev/null
echo full=$?
$SH --help >&- 2>/dev/null
echo closed=$?
## STDOUT:
full=0
closed=0
## END

#### original short h flag is parsed and ignored
$SH -h > actual.txt 2>/dev/null
echo status=$?
test -s actual.txt
echo has-output=$?
## STDOUT:
status=0
has-output=1
## END

#### large explicit usage body fails during main help writes with status two
mkdir -p resources/_devbuild/help
printf '99.88.77-fixture\n' > resources/oils-version.txt
head -c 65536 /dev/zero | tr '\000' a > resources/_devbuild/help/osh-usage
printf 'fixture flags\n' > resources/_devbuild/help/shell-flags
env _OVM_RESOURCE_ROOT="$PWD/resources" $SH --help > /dev/full 2>/dev/null
echo status=$?
## stdout: status=2
