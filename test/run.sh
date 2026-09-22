#!/bin/sh
# Every case is run against a real daukle, because this plugin's output is
# daukle.json_set's formatting and a stub of that verb would be testing the stub.
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

fail() {
  echo "FAIL $1: $2" >&2
  failed=$((failed + 1))
}

run_case() {
  case_dir=$1
  name=$(basename "$case_dir")

  for manifest in "$case_dir"/daukle*.toml; do
    manifest_name=$(basename "$manifest")
    sandbox="$work/$name-$manifest_name"
    rm -rf "$sandbox"
    mkdir -p "$(dirname "$sandbox")"
    cp -R "$case_dir" "$sandbox"
    rm -rf "$sandbox/expected" "$sandbox/expect-error.txt"
    cp "$root/plugin.lua" "$sandbox/plugins/plugin.lua"

    if [ -f "$case_dir/expect-error.txt" ]; then
      if (cd "$sandbox" && "$daukle" sync "$manifest_name" >stdout.txt 2>stderr.txt); then
        fail "$name/$manifest_name" "expected a failure, got success"
        continue
      fi
      clause=$(cat "$case_dir/expect-error.txt")
      if ! grep -qF "$clause" "$sandbox/stderr.txt" "$sandbox/stdout.txt"; then
        fail "$name/$manifest_name" "message does not carry: $clause"
        continue
      fi
      passed=$((passed + 1))
      continue
    fi

    # Twice, because applying twice must equal applying once for every case,
    # not only for the one a test remembered to say it about.
    if ! (cd "$sandbox" && "$daukle" sync "$manifest_name" >/dev/null 2>&1); then
      fail "$name/$manifest_name" "sync failed"
      continue
    fi
    if ! compare_expected "$case_dir" "$sandbox" "$name/$manifest_name (first)"; then
      continue
    fi
    if ! (cd "$sandbox" && "$daukle" sync "$manifest_name" >/dev/null 2>&1); then
      fail "$name/$manifest_name" "second sync failed"
      continue
    fi
    if ! compare_expected "$case_dir" "$sandbox" "$name/$manifest_name (second)"; then
      continue
    fi
    passed=$((passed + 1))
  done
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
  run_case "${case_dir%/}"
done

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
