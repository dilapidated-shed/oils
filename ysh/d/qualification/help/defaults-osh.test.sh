## our_shell: osh

#### default OSH help concatenates help card then OSH chapters then docs URL
help help > expected.txt
help osh-chapters >> expected.txt
printf 'All docs: https://oils.pub/release/0.37.0/doc/\n\n' >> expected.txt
help > actual.txt
cmp expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### main OSH help concatenates version then usage then shared flags
printf 'Oils 0.37.0\t\thttps://oils.pub/\n\n' > expected.txt
help osh-usage >> expected.txt
help shell-flags >> expected.txt
$SH --help > actual.txt
cmp expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### builtin OSH help is independent of the current directory
help > expected.txt
mkdir elsewhere
cd elsewhere
help > actual.txt
cmp ../expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### mapped word language topic prints exact URL and nonterminal header
help command-sub
## stdout-json: "~~~ command-sub ~~~\n\n    https://oils.pub/release/0.37.0/doc/ref/chap-word-lang.html#command-sub\n\n"
## stderr-json: ""

#### main OSH help is independent of the current directory
$SH --help > expected.txt
mkdir elsewhere
cd elsewhere
$SH --help > actual.txt
cmp ../expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### mapped builtin topic prints exact URL and nonterminal header
help read
## stdout-json: "~~~ read ~~~\n\n    https://oils.pub/release/0.37.0/doc/ref/chap-builtin-cmd.html#read\n\n"
## stderr-json: ""

#### mapped topic lookup is case sensitive
help READ 2>/dev/null
## stdout-json: ""
## status: 1
