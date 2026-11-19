## compare_shells: osh

#### getopts OPTIND prefix is read and discarded after builtin
OPTIND=2 getopts ab opt -a -b
echo "$?:$opt:$OPTIND:$OPTARG"
## stdout: 0:b:1:

#### getopts OPTERR prefix suppresses option diagnostics
OPTERR=0 getopts a opt -Z 2>error.txt
echo "$?:$opt:$OPTIND:$OPTARG:${OPTERR-undefined}"
if test -s error.txt; then echo unexpected-diagnostic; fi
## stdout: 0:?:2::undefined

#### getopts prefixed destination write is discarded after builtin
opt=seed getopts a opt -a
echo "$?:${opt-undefined}:$OPTIND:$OPTARG"
## stdout: 0:undefined:2:

#### getopts prefixed OPTARG write is discarded after builtin
OPTARG=seed getopts a: opt -a value
echo "$?:$opt:$OPTIND:${OPTARG-undefined}"
## stdout: 0:a:3:undefined

#### getopts prefix restores existing destination and argument cells
opt=outside
OPTARG=outside
opt=seed OPTARG=seed getopts a: opt -a value
echo "$?:$opt:$OPTIND:$OPTARG"
## stdout: 0:outside:3:outside
