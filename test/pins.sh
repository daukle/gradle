#!/bin/sh
# Every pinned digest, against the .sha256 gradle.org publishes beside the
# asset.
#
# The e2e cases run ONE version at each edge of the supported range, because
# each costs 137 MB of Gradle. That leaves the rows in the middle asserted by
# nothing, and a transcribed digest is exactly the kind of claim this project
# keeps finding wrong. This covers every row for one small GET each.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
table="$root/lib/distributions.lua"

if [ "${DAUKLE_GRADLE_E2E:-}" != "1" ]; then
  echo "skip pins: set DAUKLE_GRADLE_E2E=1 to check the pins against gradle.org" >&2
  exit 0
fi

# The table's own spelling is the input, so a row added without a digest cannot
# pass by being skipped: it is not parsed, and the count below then disagrees
# with the number of rows in the file.
rows=$(sed -n 's/^  \["\([^"]*\)"\] = "\([0-9a-f]\{64\}\)",$/\1 \2/p' "$table")
declared=$(grep -c '^  \["' "$table")
parsed=$(printf '%s\n' "$rows" | grep -c . || true)

if [ "$parsed" -eq 0 ] || [ "$parsed" -ne "$declared" ]; then
  echo "pins: $declared rows in lib/distributions.lua and $parsed parsed; a row this cannot" \
       "read is a row nothing checks" >&2
  exit 1
fi

failed=0
checked=0
# No pipeline: a `while read` fed by one would run in a subshell on every POSIX
# sh and lose the counters, leaving a check that is always green.
old_ifs=$IFS
IFS='
'
for row in $rows; do
  IFS=$old_ifs
  version=${row%% *}
  pinned=${row##* }
  url="https://services.gradle.org/distributions/gradle-$version-bin.zip.sha256"

  published=$(curl -sSL --fail "$url" 2>/dev/null || true)
  if [ -z "$published" ]; then
    echo "FAIL $version: $url returned nothing" >&2
    failed=$((failed + 1))
  elif [ "$published" != "$pinned" ]; then
    echo "FAIL $version: pinned $pinned, gradle.org publishes $published" >&2
    failed=$((failed + 1))
  else
    checked=$((checked + 1))
  fi
  IFS='
'
done
IFS=$old_ifs

echo "$checked of $declared pinned versions match gradle.org, $failed failed"
[ "$failed" -eq 0 ]
