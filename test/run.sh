#!/bin/sh
# Every case runs against a real daukle, and the cases that matter run a real
# Gradle against a real JDK, both provisioned by the plugin under test. A stub
# of either would be testing the stub.
#
# A case carrying "needs-tools" provisions ~280 MB and is skipped unless
# DAUKLE_GRADLE_E2E=1. CI sets it on every runner: compiling and testing through
# a provisioned Gradle is the whole of what this plugin does, and a run that
# skipped those proved only that bad input is refused.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="$root/test/.work"

daukle=${DAUKLE:-}
if [ -z "$daukle" ]; then
  for candidate in \
    "$root/.daukle/build/daukle" \
    "$root/.daukle/build/daukle.exe" \
    "$root/.daukle/build/Release/daukle.exe" \
    "$root/.daukle/build/Debug/daukle.exe"
  do
    [ -x "$candidate" ] && daukle=$candidate && break
  done
fi
if [ -z "$daukle" ] || [ ! -x "$daukle" ]; then
  echo "no daukle binary: set DAUKLE, or check out daukle/daukle into .daukle and build it" >&2
  exit 1
fi

passed=0
failed=0
skipped=0

fail() {
  echo "FAIL $1: $2" >&2
  failed=$((failed + 1))
}

run_case() {
  case_dir=$1
  name=$(basename "$case_dir")

  if [ -f "$case_dir/needs-tools" ] && [ "${DAUKLE_GRADLE_E2E:-}" != "1" ]; then
    echo "skip $name: set DAUKLE_GRADLE_E2E=1 to provision Gradle and a JDK here" >&2
    skipped=$((skipped + 1))
    return
  fi

  sandbox="$work/$name"
  rm -rf "$sandbox"
  mkdir -p "$(dirname "$sandbox")"
  cp -R "$case_dir" "$sandbox"
  rm -rf "$sandbox/expected" "$sandbox/expect-error.txt" "$sandbox/needs-tools" "$sandbox/task"
  mkdir -p "$sandbox/plugins"
  cp "$root/plugin.lua" "$sandbox/plugins/plugin.lua"
  cp -R "$root/lib" "$sandbox/plugins/lib"

  command=sync
  [ -f "$case_dir/task" ] && command=$(cat "$case_dir/task")

  if [ -f "$case_dir/expect-error.txt" ]; then
    if (cd "$sandbox" && "$daukle" $command >stdout.txt 2>stderr.txt); then
      fail "$name" "expected a failure, got success"
      return
    fi
    clause=$(cat "$case_dir/expect-error.txt")
    if ! grep -qF "$clause" "$sandbox/stderr.txt" "$sandbox/stdout.txt"; then
      echo "--- stderr ---" >&2
      cat "$sandbox/stderr.txt" >&2
      fail "$name" "message does not carry: $clause"
      return
    fi
    passed=$((passed + 1))
    return
  fi

  if ! (cd "$sandbox" && "$daukle" $command >stdout.txt 2>stderr.txt); then
    echo "--- stderr ---" >&2
    tail -40 "$sandbox/stderr.txt" >&2
    fail "$name" "$command failed"
    return
  fi

  if [ -d "$case_dir/expected" ]; then
    compare_expected "$case_dir" "$sandbox" "$name" || return
  fi

  # A case that ran a task asserts on what the TOOL produced, never on the text
  # of the generated build file. The source-set redirect in that file fails
  # silently when its path arithmetic is wrong: Gradle resolves the roots
  # against the wrong directory, finds nothing, compiles nothing and exits 0.
  # Only compiled output catches that.
  if [ -f "$case_dir/needs-tools" ]; then
    classes=$(find "$sandbox/build/daukle/gradle/build/classes" -name '*.class' 2>/dev/null | wc -l)
    if [ "$classes" -lt 2 ]; then
      fail "$name" "expected compiled classes, found $classes"
      return
    fi
    results=$(find "$sandbox/build/daukle/gradle/build/test-results" -name '*.xml' 2>/dev/null)
    if [ -z "$results" ]; then
      fail "$name" "the test task produced no results"
      return
    fi
    if ! grep -q 'tests="2"' $results || ! grep -q 'failures="0"' $results; then
      fail "$name" "expected 2 tests and 0 failures"
      grep -o 'tests="[0-9]*"[^>]*' $results >&2 || true
      return
    fi
    # Nothing Gradle writes may reach the project root. This is the property
    # the whole redirect exists for, and it is asserted rather than assumed.
    for stray in build.gradle settings.gradle .gradle gradlew; do
      if [ -e "$sandbox/$stray" ]; then
        fail "$name" "$stray reached the project root"
        return
      fi
    done
  fi

  passed=$((passed + 1))
}

compare_expected() {
  expected_root=$1/expected
  actual_root=$2
  label=$3
  ok=0
  # An empty expected/ would compare nothing and pass, which is the one way a
  # case can look green while asserting nothing at all.
  if [ -z "$(cd "$expected_root" && find . -type f)" ]; then
    fail "$label" "expected/ holds no files, so this case asserts nothing"
    return 1
  fi
  for expected in $(cd "$expected_root" && find . -type f); do
    if ! cmp -s "$expected_root/$expected" "$actual_root/$expected"; then
      fail "$label" "$expected differs"
      diff -u "$expected_root/$expected" "$actual_root/$expected" >&2 || true
      ok=1
    fi
  done
  return $ok
}

rm -rf "$work"
for case_dir in "$root"/test/cases/*/; do
  [ -d "$case_dir" ] || continue
  run_case "${case_dir%/}"
done

echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
