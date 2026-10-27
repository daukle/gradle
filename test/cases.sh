#!/bin/sh
# Every case runs against a real daukle, and the cases that matter run a real
# Gradle against a real JDK, both provisioned by the plugin under test. A stub
# of either would be testing the stub.
#
# A case carrying "needs-tools" provisions roughly 330 MB, 137 MB of Gradle and
# a JDK of about 190 MB, and is skipped unless DAUKLE_GRADLE_E2E=1. CI sets it
# on every runner: compiling and testing through a provisioned Gradle is the
# whole of what this plugin does, and a run that skipped those proved only that
# bad input is refused.
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

# The value an `{ env = ... }` marker is checked against. An ordinary variable
# rather than a credential on purpose: what a case needs to prove is that the
# marker reaches Gradle, and core's own suite proves the allowlist that governs
# a credential. Exporting GITHUB_TOKEN here would also fight whatever CI sets.
DAUKLE_GRADLE_PROBE=marker-probe
export DAUKLE_GRADLE_PROBE

passed=0
failed=0
skipped=0

fail() {
  echo "FAIL $1: $2" >&2
  failed=$((failed + 1))
}

# One literal per line the run's own output must carry. It is how a case
# asserts that a value the manifest names reached the TOOL rather than the
# renderer: "provisioning gradle 9.6.0" is daukle's own line, and nothing
# else in a build names the Gradle that ran. Both cases named after Gradle 9
# were green on Gradle 8.13 from the day they were written, because the
# manifest's version reached generate and no check looked at the task.
output_carries_clauses() {
  if [ -f "$case_dir/expect-output.txt" ]; then
    if ! grep -q . "$case_dir/expect-output.txt"; then
      fail "$name" "expect-output.txt is empty, so this case asserts nothing"
      return 1
    fi
    while IFS= read -r clause || [ -n "$clause" ]; do
      [ -n "$clause" ] || continue
      if ! grep -qF "$clause" "$sandbox/stdout.txt" "$sandbox/stderr.txt"; then
        fail "$name" "output does not carry: $clause"
        return 1
      fi
    done < "$case_dir/expect-output.txt"
  fi
  return 0
}

# "<path> <literal>" per line, for an assertion about what is INSIDE a file
# the tool produced. A zip stores its entry NAMES uncompressed in the central
# directory, so grepping a jar for an entry name needs no unzip on the runner;
# its entry CONTENTS are deflated and are not greppable, which is why nothing
# here asserts a jar MANIFEST and why the fat-jar case proves its Main-Class
# by RUNNING the jar instead. Measured both ways in daukle/java, D-81.
files_carry_literals() {
  if [ -f "$case_dir/expect-contains.txt" ]; then
    if ! grep -q . "$case_dir/expect-contains.txt"; then
      fail "$name" "expect-contains.txt is empty, so this case asserts nothing"
      return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      target=${line%% *}
      literal=${line#* }
      if [ ! -f "$sandbox/$target" ]; then
        fail "$name" "expected $target, which the build did not produce"
        return 1
      fi
      if ! grep -qF "$literal" "$sandbox/$target"; then
        fail "$name" "$target does not carry: $literal"
        return 1
      fi
    done < "$case_dir/expect-contains.txt"
  fi
  return 0
}

# expect-blocks.txt holds blocks separated by a "--" line: a path, then lines
# the file must carry CONSECUTIVELY, each compared with its surrounding
# whitespace removed, so a blank line stands for a whitespace-only one. It is
# how a case asserts a value that a pretty-printed JSON file spreads over lines
# (an array's elements, or the key that says which statement a value is in),
# which one grep literal cannot tie together.
BLOCK_CHECK='
import sys
blocks, current = [], []
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if line.strip() == "--":
        blocks.append(current)
        current = []
    else:
        current.append(line)
blocks.append(current)
for block in [block for block in blocks if block]:
    target, wanted = block[0].strip(), [line.strip() for line in block[1:]]
    try:
        lines = [line.strip() for line in open(sys.argv[2] + "/" + target, encoding="utf-8").read().splitlines()]
    except OSError:
        print("expected " + target + ", which the run did not produce")
        sys.exit(1)
    if not any(lines[at:at + len(wanted)] == wanted for at in range(len(lines))):
        print(target + " does not carry, as consecutive lines: " + " / ".join(wanted))
        sys.exit(1)
'

files_carry_blocks() {
  [ -f "$case_dir/expect-blocks.txt" ] || return 0
  if ! grep -q '[^-[:space:]]' "$case_dir/expect-blocks.txt"; then
    fail "$name" "expect-blocks.txt is empty, so this case asserts nothing"
    return 1
  fi
  python=$(working_python) || { fail "$name" "no python3 or python that runs"; return 1; }
  if ! missing=$("$python" -c "$BLOCK_CHECK" "$case_dir/expect-blocks.txt" "$sandbox"); then
    fail "$name" "$missing"
    return 1
  fi
  return 0
}

# The negation of expect-contains.txt, same "<path> <literal>" lines: an entry
# a configuration must keep OUT of an archive cannot be proved by presence.
files_lack_literals() {
  [ -f "$case_dir/expect-lacks.txt" ] || return 0
  if ! grep -q . "$case_dir/expect-lacks.txt"; then
    fail "$name" "expect-lacks.txt is empty, so this case asserts nothing"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    target=${line%% *}
    literal=${line#* }
    if [ ! -f "$sandbox/$target" ]; then
      fail "$name" "expected $target, which the build did not produce"
      return 1
    fi
    if grep -qF "$literal" "$sandbox/$target"; then
      fail "$name" "$target carries: $literal"
      return 1
    fi
  done < "$case_dir/expect-lacks.txt"
  return 0
}

# expect-manifest.txt holds paragraphs, separated by a blank line, that the
# daukle.toml a migration wrote must carry. Every line of a paragraph must sit
# in ONE table of it (a header line included), in any order, because core
# writes a table's keys in Lua's iteration order; a pinned entry's bucket is
# asserted by putting its header and its url in one paragraph. A line starting
# with "!" is a prefix no line may start with in a table that carries the
# paragraph's other lines, so a paragraph of just "!release =" means no table
# sets release at all.
MANIFEST_CHECK='
import sys
sections, current = [], []
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if line.startswith("["):
        sections.append(current)
        current = []
    current.append(line)
sections.append(current)
paragraphs = [[]]
for line in open(sys.argv[2], encoding="utf-8").read().splitlines():
    if line.strip():
        paragraphs[-1].append(line)
    elif paragraphs[-1]:
        paragraphs.append([])
paragraphs = [paragraph for paragraph in paragraphs if paragraph]
for paragraph in paragraphs:
    wanted = [line for line in paragraph if not line.startswith("!")]
    refused = [line[1:] for line in paragraph if line.startswith("!")]
    carrying = [section for section in sections if all(line in section for line in wanted)]
    if (wanted and not carrying) or any(line.startswith(prefix) for section in carrying for line in section for prefix in refused):
        print(" / ".join(paragraph))
        sys.exit(1)
'

manifest_carries_clauses() {
  [ -f "$case_dir/expect-manifest.txt" ] || return 0
  if ! grep -q . "$case_dir/expect-manifest.txt"; then
    fail "$name" "expect-manifest.txt is empty, so this case asserts nothing"
    return 1
  fi
  if [ ! -f "$sandbox/daukle.toml" ]; then
    fail "$name" "expected daukle.toml, which the migration did not write"
    return 1
  fi
  python=$(working_python) || { fail "$name" "no python3 or python that runs"; return 1; }
  if ! missing=$("$python" -c "$MANIFEST_CHECK" "$sandbox/daukle.toml" "$case_dir/expect-manifest.txt"); then
    fail "$name" "daukle.toml does not match, in one table: $missing"
    return 1
  fi
  return 0
}

# On Windows python3 can be the WindowsApps stub that only opens the Store, so
# a candidate counts only once it has run.
working_python() {
  for candidate in python3 python; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import sys' >/dev/null 2>&1 && { echo "$candidate"; return 0; }
  done
  return 1
}

# Port 0 lets the system pick, because a fixed port can fall in a range Windows
# reserves for Hyper-V and refuses to bind.
PLUGIN_SERVER='
import functools, http.server, os, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
with open(sys.argv[2] + ".tmp", "w") as out:
    out.write(str(server.server_port))
os.replace(sys.argv[2] + ".tmp", sys.argv[2])
server.serve_forever()
'

# daukle migrate finds a plugin only through a catalog, whose asset is pinned
# by url and sha256 and taken over https or loopback http alone. So the plugin
# is packed exactly as publish.yml packs it and served from 127.0.0.1, once per
# run. Copied from daukle/node's harness, which measured both constraints.
serve_plugin() {
  [ -n "${catalog:-}" ] && return 0
  python=$(working_python) || { fail "$name" "no python3 or python that runs"; return 1; }
  asset_dir="$work/asset"
  mkdir -p "$asset_dir"
  # COPYFILE_DISABLE and ustar keep macOS bsdtar from adding AppleDouble or pax
  # members, and core's tar reader takes only regular files and directories.
  packed="$work/plugin.tar"
  (cd "$root" && COPYFILE_DISABLE=1 tar --format=ustar -cf "$packed" plugin.lua lib/*.lua)
  digest=$(sha256sum "$packed" 2>/dev/null | cut -d' ' -f1)
  [ -n "$digest" ] || digest=$(shasum -a 256 "$packed" | cut -d' ' -f1)
  # Served under its own digest because core caches a plugin by its url, and a
  # port an earlier run used would hand back that run's lib/.
  mkdir -p "$asset_dir/$digest"
  mv "$packed" "$asset_dir/$digest/plugin.lua"
  port_file="$work/server-port"
  rm -f "$port_file"
  "$python" -c "$PLUGIN_SERVER" "$asset_dir" "$port_file" >"$work/server.log" 2>&1 &
  server=$!
  trap 'kill "$server" 2>/dev/null || true' EXIT
  port=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$port_file" ] && port=$(cat "$port_file") &&
      curl -fsS "http://127.0.0.1:$port/$digest/plugin.lua" -o /dev/null 2>/dev/null && break
    port=
    kill -0 "$server" 2>/dev/null || break
    sleep 1
  done
  if [ -z "$port" ]; then
    fail "$name" "the plugin server did not start, so no migrate case can run: $(cat "$work/server.log")"
    return 1
  fi
  catalog="$work/catalog.json"
  "$python" -c 'import json,sys; c=json.load(open(sys.argv[1])); c.update(id="gradle", asset={"url":sys.argv[2],"sha256":sys.argv[3]}); json.dump({"plugins":[c]}, open(sys.argv[4],"w"))' \
    "$root/catalog.json" "http://127.0.0.1:$port/$digest/plugin.lua" "$digest" "$catalog"
}

# One path per line in expect-file.txt that must exist after the run, and in
# expect-absent.txt that must not: what a migration moved aside and what it
# kept is asserted on the tree itself, never on the message that reports it.
tree_has_paths() {
  for list in expect-file.txt expect-absent.txt; do
    [ -f "$case_dir/$list" ] || continue
    if ! grep -q . "$case_dir/$list"; then
      fail "$name" "$list is empty, so this case asserts nothing"
      return 1
    fi
    while IFS= read -r wanted || [ -n "$wanted" ]; do
      [ -n "$wanted" ] || continue
      if [ "$list" = expect-file.txt ] && [ ! -e "$sandbox/$wanted" ]; then
        fail "$name" "expected $wanted, which the run did not leave"
        return 1
      fi
      if [ "$list" = expect-absent.txt ] && [ -e "$sandbox/$wanted" ]; then
        fail "$name" "$wanted is still there"
        return 1
      fi
    done < "$case_dir/$list"
  done
  return 0
}

# A migrate case asserts its exit code (expect-exit.txt), then what the output
# and the files it names carry and lack, with the same expect-output.txt,
# expect-contains.txt, expect-blocks.txt and expect-lacks.txt every other case
# uses, then expect-manifest.txt, then the paths it expects present and absent.
run_migrate_case() {
  serve_plugin || return 0
  status=0
  (cd "$sandbox" && "$daukle" migrate --catalog "$catalog" >stdout.txt 2>stderr.txt) || status=$?
  wanted=$(cat "$case_dir/expect-exit.txt")
  if [ "$status" -ne "$wanted" ]; then
    fail "$name" "migrate exited $status, wanted $wanted"
    echo "--- stdout" >&2
    tail -n 30 "$sandbox/stdout.txt" >&2
    echo "--- stderr" >&2
    tail -n 30 "$sandbox/stderr.txt" >&2
    return 0
  fi
  output_carries_clauses || return 0
  files_carry_literals || return 0
  files_carry_blocks || return 0
  files_lack_literals || return 0
  manifest_carries_clauses || return 0
  tree_has_paths || return 0
  passed=$((passed + 1))
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
  rm -rf "$sandbox/expected" "$sandbox/expect-error.txt" "$sandbox/needs-tools" "$sandbox/task" \
         "$sandbox/expect-file.txt" "$sandbox/expect-output.txt" "$sandbox/expect-contains.txt" \
         "$sandbox/expect-lacks.txt" "$sandbox/expect-blocks.txt" "$sandbox/resolve" \
         "$sandbox/expect-absent.txt" "$sandbox/task-after" "$sandbox/daukle.after.toml"
  if [ -f "$case_dir/migrate" ]; then
    rm -f "$sandbox/migrate" "$sandbox/expect-exit.txt" "$sandbox/expect-manifest.txt"
    run_migrate_case
    return
  fi
  mkdir -p "$sandbox/plugins"
  cp "$root/plugin.lua" "$sandbox/plugins/plugin.lua"
  cp -R "$root/lib" "$sandbox/plugins/lib"

  command=sync
  [ -f "$case_dir/task" ] && command=$(cat "$case_dir/task")
  # A run that may pin an unpinned url or write a committed file, which core allows only then.
  [ -f "$case_dir/resolve" ] && command="$command --resolve"

  # A case about what one run leaves for the next: `task` runs first and must
  # succeed, then daukle.after.toml replaces the manifest and `task-after` is
  # the run every expectation below is about.
  if [ -f "$case_dir/task-after" ]; then
    if ! (cd "$sandbox" && "$daukle" $command >stdout.txt 2>stderr.txt); then
      echo "--- stderr ---" >&2
      tail -40 "$sandbox/stderr.txt" >&2
      fail "$name" "the first run, $command, failed"
      return
    fi
    cp "$case_dir/daukle.after.toml" "$sandbox/daukle.toml"
    command=$(cat "$case_dir/task-after")
  fi

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
    output_carries_clauses || return 0
    files_carry_literals || return 0
    tree_has_paths || return 0
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
    # A bare return passes the diff's status up, and set -e then ends the whole run.
    compare_expected "$case_dir" "$sandbox" "$name" || return 0
  fi

  output_carries_clauses || return 0

  # One path per line that the TOOL must have produced. The text of a generated
  # file proves what daukle wrote; only a file Gradle made proves Gradle read it,
  # and a value rendered into a name is the cheapest thing to look at.
  if [ -f "$case_dir/expect-file.txt" ]; then
    while IFS= read -r wanted; do
      [ -n "$wanted" ] || continue
      if [ ! -e "$sandbox/$wanted" ]; then
        fail "$name" "expected $wanted, which the build did not produce"
        return
      fi
    done < "$case_dir/expect-file.txt"
  fi

  files_carry_literals || return 0
  files_carry_blocks || return 0
  files_lack_literals || return 0
  tree_has_paths || return 0

  # A case that ran a task asserts on what the TOOL produced, never on the text
  # of the generated build file. The source-set redirect in that file fails
  # silently when its path arithmetic is wrong: Gradle resolves the roots
  # against the wrong directory, finds nothing, compiles nothing and exits 0.
  # Only compiled output catches that.
  # Every needs-tools case must assert on something the TOOL produced, and
  # compiled classes are what a case asserts when it names nothing more
  # specific. A case carrying expected/ or expect-file.txt has named something
  # stronger, and gradle:discover compiles nothing at all.
  if [ -f "$case_dir/needs-tools" ] \
     && [ ! -d "$case_dir/expected" ] && [ ! -f "$case_dir/expect-file.txt" ]; then
    classes=$(find "$sandbox/build/daukle/gradle/build/classes" -name '*.class' 2>/dev/null | wc -l)
    if [ "$classes" -lt 2 ]; then
      fail "$name" "expected compiled classes, found $classes"
      return
    fi
    # Only a case that ran the test task; a case built around applying a plugin
    # compiles and never runs a test, and demanding results of it would be a
    # check that passes for the wrong reason or not at all.
    if [ "$command" = "gradle:test" ]; then
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
    fi
  fi

  # Nothing Gradle writes may reach the project root. This is the property the
  # whole redirect exists for, it is asserted rather than assumed, and it is
  # asserted for the EXAMPLE as well: the example is the one place a reader
  # looks to see what a project holds.
  if [ -f "$case_dir/needs-tools" ]; then
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
  if [ -n "${DAUKLE_CASE:-}" ] && [ "$(basename "$case_dir")" != "$DAUKLE_CASE" ]; then
    continue
  fi
  run_case "${case_dir%/}"
done

echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
