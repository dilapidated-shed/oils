## our_shell: ysh

#### default YSH help concatenates help card then YSH chapters then docs URL
help help > expected.txt
help ysh-chapters >> expected.txt
printf 'All docs: https://oils.pub/release/0.37.0/doc/\n\n' >> expected.txt
help > actual.txt
cmp expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### main YSH help is independent of the current directory
$[ENV.SH] --help > expected.txt
mkdir elsewhere
cd elsewhere
$[ENV.SH] --help > actual.txt
cmp ../expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### main YSH help concatenates version then usage then shared flags
printf 'Oils 0.37.0\t\thttps://oils.pub/\n\n' > expected.txt
help ysh-usage >> expected.txt
help shell-flags >> expected.txt
$[ENV.SH] --help > actual.txt
cmp expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### builtin YSH help is independent of the current directory
help > expected.txt
mkdir elsewhere
cd elsewhere
help > actual.txt
cmp ../expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""
