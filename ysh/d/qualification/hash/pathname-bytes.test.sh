## compare_shells: osh

#### hash rejects an explicit pathname containing NUL before caching
$SH 2>/dev/null <<'EOF'
trap 'echo child-exit=$?' EXIT
hash $'/bin/echo\0suffix'
echo resumed
EOF
echo child=$?
## stdout: child=1

#### external lookup rejects an explicit pathname containing NUL
$SH 2>/dev/null <<'EOF'
trap 'echo child-exit=$?' EXIT
$'/bin/echo\0suffix' survived
echo resumed
EOF
echo child=$?
## stdout: child=1

#### reflection rejects an explicit pathname containing NUL
$SH 2>/dev/null <<'EOF'
trap 'echo child-exit=$?' EXIT
command -v $'/bin/echo\0suffix'
echo resumed
EOF
echo child=$?
## stdout: child=1

#### PATH candidate validation rejects NUL before C string conversion
$SH 2>/dev/null <<'EOF'
trap 'echo child-exit=$?' EXIT
PATH=$'/bin/echo\0ignore'
hash nulpayload
nulpayload survived
echo resumed
EOF
echo child=$?
## stdout: child=1
