## compare_shells: osh
# Evidence-only fixture for the retained actual minimal Python build.
# Native primary resources and metadata are canonical full-build resources.

#### minimal build does not fabricate embedded help
for topic in help oils-usage osh-usage ysh-usage osh-chapters ysh-chapters; do
  help "$topic" 2>/dev/null
  echo "$topic=$?"
done
## STDOUT:
help=1
oils-usage=1
osh-usage=1
ysh-usage=1
osh-chapters=1
ysh-chapters=1
## END

#### minimal build does not fabricate topic metadata
for topic in command-sub read List/append cmd/append runes; do
  help "$topic" 2>/dev/null
  echo "$topic=$?"
done
## STDOUT:
command-sub=1
read=1
List/append=1
cmd/append=1
runes=1
## END

#### minimal topic paths and empty topic are ordinary missing resources
for topic in '' . .. / ../oils-version.txt ../../oils-version.txt; do
  help "$topic" 2>/dev/null
  echo status=$?
done
## STDOUT:
status=1
status=1
status=1
status=1
status=1
status=1
## END

#### minimal default help aborts without subsequent commands or EXIT trap
$SH -c 'trap "echo unexpected-trap" EXIT; help; echo unexpected-after' 2>/dev/null
echo status=$?
## stdout: status=1

#### minimal main help prints source version then fails for absent usage
$SH --help 2>/dev/null
echo status=$?
## STDOUT:
Oils 0.37.0		https://oils.pub/

status=1
## END
