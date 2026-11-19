## compare_shells: osh
# Explicit synthetic resource data checks the original loader interface.
# These bytes are test data, not purported product help cards.

#### explicit file root supplies version and literal help card bytes
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\nignored-version-line\n' > resources/oils-version.txt
printf 'fixture body\n' > resources/_devbuild/help/fixture-card
env _OVM_RESOURCE_ROOT="$PWD/resources" $SH -c 'help fixture-card'
## stdout-json: "~~~ fixture-card ~~~\n\nfixture body\n\n"
## stderr-json: ""

#### explicit file root version stops at the first LF
mkdir resources
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\nignored-version-line\n' > resources/oils-version.txt
env _OVM_RESOURCE_ROOT="$PWD/resources" $SH -c 'help OILS-ERR-12'
## stdout-json: "\n    https://oils.pub/release/99.88.77-fixture/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### explicit file root preserves a CR before the first version LF
mkdir resources
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\r\nignored\n' > resources/oils-version.txt
env _OVM_RESOURCE_ROOT="$PWD/resources" $SH -c 'help oils-err-12'
## stdout-json: "\n    https://oils.pub/release/99.88.77-fixture\r/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### explicit file root preserves an empty card and adds exactly one LF
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\n' > resources/oils-version.txt
: > resources/_devbuild/help/fixture-empty
env _OVM_RESOURCE_ROOT="$PWD/resources" $SH -c 'help fixture-empty'
## stdout-json: "~~~ fixture-empty ~~~\n\n\n"
## stderr-json: ""

#### explicit file root preserves binary card bytes without newline repair
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\n' > resources/oils-version.txt
printf '\000\377no-final-LF' > resources/_devbuild/help/fixture-binary
printf '~~~ fixture-binary ~~~\n\n\000\377no-final-LF\n' > expected.txt
env _OVM_RESOURCE_ROOT="$PWD/resources" $SH -c 'help fixture-binary' > actual.txt
cmp expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### original file-loader topic routing preserves parent path components
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\n' > resources/oils-version.txt
printf 'outside card directory\n' > resources/fixture-outside
env _OVM_RESOURCE_ROOT="$PWD/resources" $SH -c 'help ../../fixture-outside'
## stdout-json: "~~~ ../../fixture-outside ~~~\n\noutside card directory\n\n"
## stderr-json: ""

#### missing file-root card returns one without embedded fallback
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\n' > resources/oils-version.txt
env _OVM_RESOURCE_ROOT="$PWD/resources" $SH -c 'help help' 2>/dev/null
echo status=$?
## stdout: status=1

#### relative file root remains relative when later card lookup follows cd
mkdir -p resources/_devbuild/help elsewhere
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\n' > resources/oils-version.txt
printf 'fixture body\n' > resources/_devbuild/help/fixture-card
env _OVM_RESOURCE_ROOT=resources $SH -c 'cd elsewhere; help fixture-card 2>/dev/null; echo missing=$?; help oils-err-12'
## STDOUT:
missing=1

    https://oils.pub/release/99.88.77-fixture/doc/error-catalog.html#oils-err-12

## END
## stderr-json: ""

#### terminal stdout uses exact reverse-video header bytes
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-fixture\n' > resources/oils-version.txt
printf 'fixture body\n' > resources/_devbuild/help/fixture-card
printf '\033[7m fixture-card \033[0;0m\r\n\r\nfixture body\r\n\r\n' > expected.txt
env _OVM_RESOURCE_ROOT="$PWD/resources" script -q -e -c "$SH -c 'help fixture-card'" /dev/null > actual.txt
cmp expected.txt actual.txt
echo status=$?
## stdout: status=0
## stderr-json: ""

#### stored ZIP resource mode takes precedence over an invalid file root
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-zip\n' > resources/oils-version.txt
printf 'zip body\n' > resources/_devbuild/help/fixture-card
cd resources
zip -q -0 ../resources.zip oils-version.txt _devbuild/gen/grammar.marshal _devbuild/help/fixture-card
cd ..
env _OVM_IS_BUNDLE=1 _OVM_PATH="$PWD/resources.zip" _OVM_RESOURCE_ROOT=absent $SH -c 'help fixture-card; help oils-err-12'
## stdout-json: "~~~ fixture-card ~~~\n\nzip body\n\n\n    https://oils.pub/release/99.88.77-zip/doc/error-catalog.html#oils-err-12\n\n"
## stderr-json: ""

#### deflated ZIP resource mode preserves exact card bytes
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-zip\n' > resources/oils-version.txt
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > resources/_devbuild/help/fixture-card
cd resources
zip -q -9 ../resources.zip oils-version.txt _devbuild/gen/grammar.marshal _devbuild/help/fixture-card
cd ..
env _OVM_IS_BUNDLE=1 _OVM_PATH="$PWD/resources.zip" $SH -c 'help fixture-card'
## stdout-json: "~~~ fixture-card ~~~\n\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\n"
## stderr-json: ""

#### ZIP resource mode accepts an appended archive with executable prefix bytes
mkdir -p resources/_devbuild/help
mkdir -p resources/_devbuild/gen
cp "$REPO_ROOT/_devbuild/gen/grammar.marshal" resources/_devbuild/gen/grammar.marshal
printf '99.88.77-zip\n' > resources/oils-version.txt
printf 'zip body\n' > resources/_devbuild/help/fixture-card
cd resources
zip -q -0 ../resources.zip oils-version.txt _devbuild/gen/grammar.marshal _devbuild/help/fixture-card
cd ..
printf 'executable-prefix\000bytes' > appended.zip
cat resources.zip >> appended.zip
env _OVM_IS_BUNDLE=1 _OVM_PATH="$PWD/appended.zip" $SH -c 'help fixture-card'
## stdout-json: "~~~ fixture-card ~~~\n\nzip body\n\n"
## stderr-json: ""
