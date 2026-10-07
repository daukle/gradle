# Authoring notes

`plugin.lua` plus `lib/` is the whole plugin. It is published as a release asset, one uncompressed
tar of the four files, and acquired by a `[plugins]` entry naming `daukle/gradle@<range>`.

It declares `uses = { "provision", "artifact", "exec", "write" }`,
`env = { "GITHUB_TOKEN" }` and `requires = { java = ... }`.

**This repository used to hold a `daukle.language` dependency writer** that edited a `build.gradle`
you owned. It was replaced rather than kept beside the toolchain, because core refuses one chunk to
declare a language and `exec`/`provision` together, and because nothing consumed it: `daukle/gradle`
had no release and no consumer outside daukle's own fixtures. `c` and `node` each cost a second
repository to protect consumers that existed; there was nothing here to protect. `D-90`.

## How to run it

```toml
[plugins]
maven  = "daukle/maven@^1"
gradle = "daukle/gradle@^1"

[toolchains.maven]
coordinates     = ["org.slf4j:slf4j-api:1.7.36"]
testCoordinates = [
  "org.junit.jupiter:junit-jupiter:5.10.1",
  "org.junit.platform:junit-platform-launcher:1.10.1",
]
for = "gradle"

[toolchains.gradle]
release = "8"
```

```lua
-- daukle.lua, added AFTER the first resolve: daukle.include raises on a file
-- that is not there, and the first resolve is the run that creates it.
daukle.include("daukle/maven/classpath.lua")
```

```sh
daukle maven:resolve --resolve   # once, and commit daukle/maven/classpath.lua
daukle gradle:classes
daukle gradle:test
daukle gradle:jar
daukle gradle:run                # needs "main"
```

## Keys

| key | meaning |
| --- | --- |
| `version` | which Gradle to provision. Defaults to `8.13`. Pinned: **`8.13`, `8.14`, `8.14.4`, `9.3.1`, `9.6.0`**, and a version not in that set is refused by name rather than fetched |
| `jdk` | which JDK to provision, through `daukle/java`'s table. Defaults to `17` |
| `sourceRoot` | defaults to `src/main/java` |
| `resourceRoot` | defaults to `src/main/resources` |
| `testSourceRoot` | defaults to `src/test/java` |
| `testResourceRoot` | defaults to `src/test/resources` |
| `release` | Java source and target level, e.g. `"8"` |
| `main` | the class `gradle:run` runs |
| `classpath`, `testClasspath` | pinned entries, normally written by `daukle/maven` |
| `plugins` | a list of `{ id, version }`, one `apply plugin:` line each |
| `pluginClasspath` | pinned entries the plugins are applied FROM, normally written by `daukle/maven` into its own resolution |
| `configure` | a free-form tree, one Groovy block per extension |

## Third-party Gradle plugins

**The generated build still declares no `repositories {}`.** A plugin is applied from a jar daukle
pinned, on the buildscript classpath, which is the pair that keeps `repositories declared` at zero:

```toml
[toolchains.maven]
for = "gradle"
coordinates = ["org.slf4j:slf4j-api:1.7.36"]

  # A plugin marker is an ordinary POM whose single dependency is the real
  # artifact, so acquiring a plugin is acquiring a coordinate. It lives on the
  # Plugin Portal, which Central does not mirror, so it needs its own closure.
  [[toolchains.maven.resolve]]
  repository  = "https://plugins.gradle.org/m2"
  coordinates = ["io.github.intisy.github-gradle:io.github.intisy.github-gradle.gradle.plugin:1.8.2.1"]
  into        = "pluginClasspath"

[toolchains.gradle]
release = "8"

  [[toolchains.gradle.plugins]]
  id      = "io.github.intisy.github-gradle"
  version = "1.8.2.1"

  [toolchains.gradle.configure.github]
  accessToken = { env = "GITHUB_TOKEN" }

  [toolchains.gradle.configure.publishGithub]
  releaseName = "Release 1.2.3"

    [[toolchains.gradle.configure.publishGithub.artifacts.artifact]]
    classifier = ""
    jar        = { buildOutput = "libs/java-utils.jar" }
```

**Nothing in this plugin knows what `publishGithub` is.** A `configure` tree becomes nested Groovy
text by shape: a string, number or boolean becomes an assignment, a table becomes a block, and a
TOML array of tables becomes the same block repeated. That is possible only because this plugin
GENERATES a file rather than configuring a live project; reflection against the extension's own
methods hits an overload mismatch between `artifacts(Action)` and `artifacts(Closure)` and was the
wrong model.

**Keys are emitted sorted, values before blocks**, because Lua's `pairs` order is undefined and a
test compares the file byte for byte.

### The three markers, and why each is a table rather than a string

A magic prefix inside a string is a thing a real value collides with one day, so each is a one-key
table. Every spelling was run on Gradle 8.13 and 9.6.0.

| written | rendered | for |
| --- | --- | --- |
| `{ file = "assets" }` | `new File(file('../../..'), 'assets')` | a path in YOUR tree |
| `{ buildOutput = "libs/x.jar" }` | `layout.buildDirectory.file('libs/x.jar').get().asFile` | a path Gradle produced |
| `{ env = "GITHUB_TOKEN" }` | `System.getenv('GITHUB_TOKEN') ?: ''` | a value that may not be committed |

**`file` and `buildOutput` are a PAIR because daukle moved the project directory out from under a
hand-written path.** In a build file at the project root, `file('assets')` meant the root and
`file('build/libs/x.jar')` meant the build directory, and both were spelled the same way. Here the
root is three levels up and the build directory is Gradle's own, so one marker would be silently
wrong for whichever half it did not serve. Measured over this tree's `build.gradle` files, the two
kinds are roughly half each, which is why neither could be the default.

**A one-key table whose key is `file`, `buildOutput` or `env` is a marker, and anything else is a
block.** The cost is that a plugin with a real nested block named exactly `file` and holding one
string key cannot be expressed; nothing in this tree has one. A table that MIXES a marker key with
others is refused, which is the mistake that shape invites.

### GITHUB_TOKEN reaches Gradle and DAUKLE_TOKEN does not

`daukle.plugin{ env = { "GITHUB_TOKEN" } }`. Core scrubs every credential it knows from a child a
plugin starts unless that plugin declared it, so without the declaration the rendered
`System.getenv('GITHUB_TOKEN') ?: ''` hands Gradle an empty string with nothing saying why. 56 of
this tree's 77 build files apply a plugin that takes a token, which is what makes this the one
worth passing. `DAUKLE_TOKEN` is refused by name in `lib/build_file.lua`: it is daukle's own
credential, it is scrubbed, and a refusal is better than an empty string.

**That declaration did nothing until 2026-10-07**, when the measurement below found core never
copied a chunk's `env` into a TASK's slot, so every other callback honoured the allowlist and the
only one allowed to `exec` ran with an empty one. Fixed in core with its own pair of tests.

### What a `configure` block CANNOT be checked for

**A block naming an extension no applied plugin registered is not caught when the file is
written**, and the spec said it would be. It cannot be: this plugin holds no plugin knowledge, so it
cannot know which extensions a jar registers, and `configure.java` or `configure.jar` is legitimate
with no third-party plugin applied at all. Gradle's own failure names the block
(`Could not find method noSuchExtension()`), measured on 8.13, which is most of what a check would
have said. What IS refused here: a `configure` entry that is not a block, a mixed marker table, a
marker whose value is not a string, `DAUKLE_TOKEN`, a `plugins` entry with no `id` or `version`, a
`plugins` list with an empty `pluginClasspath`, and a plugin version no pinned entry carries.

### A TOML integer arrives as a float

Core carries the manifest through JSON and pushes every number with `lua_pushnumber`, so a plugin
cannot tell `7` from `7.0`. An integral value is written as a Groovy integer, which is right for the
spelling anybody uses and wrong for a property that genuinely wants `7.0`.

## What the generation does, and the one number in it that is load bearing

`settings.gradle` is generated by the toolchain's `generate` hook. **`build.gradle` is not, and the
split is forced rather than chosen**: a dependency line is an absolute path to a resolved artifact,
`daukle.artifact` is refused inside `generate`, and the refusal says why, *"generation is a pure
function of the manifest"*. So the file needing no acquisition is born in `generate` and the one
that does is written by each task through `daukle.write`, which lands in the same derived directory.

The generated source sets point back at the real tree with
`new File(file('../../..'), '<sourceRoot>')`. **`../../..` is three levels because the derived
directory is `build/daukle/gradle/`, and getting it wrong fails SILENTLY**: Gradle resolves the
roots against the wrong directory, finds nothing, compiles nothing and exits 0 on `classes`.
**That is why every test asserts on compiled output and never on the text of the generated file.**

`options.encoding` is pinned to UTF-8 rather than inherited. `java-utils`' own build carries a
comment recording that Gradle 8.11.1 read its sources as Cp1252 on Windows where 7.6.4 read them as
UTF-8, so an unpinned encoding makes the compiled bytes a property of whichever build ran. It
matters more here than in a hand-written build, because the user cannot see this file.

## Why the launcher jar rather than `bin/gradle`

`bin/gradle` is a POSIX shell script and `bin/gradle.bat` a batch file, and neither is a program
daukle can start on every host. `lib/gradle-launcher-<version>.jar` is what both scripts eventually
exec, so it is started directly with the provisioned `java`.

**That is also why no `JAVA_HOME` is set.** Gradle reports the daemon JVM as *"no JDK specified,
using current Java home"*, which is the JDK daukle provisioned, so the environment allowlist
(`D-32`) never enters into it. The design proposed setting `JAVA_HOME` and the measurement made it
unnecessary.

## Pinning Gradle is the easy half

`services.gradle.org` publishes a `.sha256` beside **every** distribution, from its own host. That
is the exact opposite of Maven Central, which publishes `.jar.sha256` for none of the twenty
artifacts `D-77` measured and is the whole reason `daukle.pin` exists. So a Gradle is pinned like a
JDK: a table in `lib/`, transcribed from the publisher's attestation, moving only with a release of
this plugin. **No new core verb and no `--resolve`.**

### Which versions the table carries, and why it is not just the newest

**A project's Gradle version is the project's decision, not daukle's**, so the table covers a RANGE.
Measured 2026-10-06 over the 190 `gradle-wrapper.properties` files under `F:/Documents/GitHub`:
**18 distinct versions, 6.7 through 9.3.1**, with `9.3.1` (79) and `8.14` (59) dominating and 8.x
still the majority at 106 against 84. **Pinning only the newest would have served none of them**,
because nothing in the tree declares `9.6.0`.

**A row is a url and a digest, so rows are cheap and CI is not.** The e2e cases therefore run one
version at each EDGE of the range, `8.13` and `9.6.0`, which is not decoration: the same build that
works on 8 fails outright on 9 for want of a `junit-platform-launcher` that is in no POM graph.
A single-major suite would have shipped that.

**The rows in between are covered by `test/pins.sh`**, which checks every pinned digest against the
`.sha256` gradle.org publishes. It costs one small GET per row, it fails on a wrong digest, and it
**fails on a row it cannot parse** rather than skipping it, because a row nothing reads is a row
nothing checks.

## The JDK table is `daukle/java`'s

`requires = { java = ... }` and `daukle.require("java:lib/jdks")`. One table, one download for a
project using both toolchains.

**The rule that a required module runs under the DEPENDENT's `uses` was expected to block this and
does not**, measured before being relied on. That rule forced `daukle/maven` to be its own plugin
rather than a library, because a resolver FETCHES. `lib/jdks` calls no verb at all: it computes a
url and a digest and returns them, so there is nothing for the dependent's `uses` to cover. **The
test is what the module does, not that it is required.**

The cost taken is that the two plugins' release cycles couple: a `daukle/java` release that changes
`lib/jdks` needs a release here to pick it up. Same bargain `daukle/cmake` already makes with
`daukle/c` and `daukle/lifecycle`.

**`root:tool(jdk.home .. "/bin/java")`, not `root:tool("bin/java")`.** The unpacker strips no
leading component, so the executable sits under the archive's own directory, and `lib/jdks` returns
`pick.home` for exactly that.

## Tests

`test/cases.sh` runs every directory under `test/cases/` against a real daukle, and the cases that
matter run a **real Gradle against a real JDK, both provisioned by the plugin under test**. The
example runs under core's `tools/run-examples.sh`, so it is a red suite when it stops working rather
than something noticed later, which is `D-45`. `test/pins.sh` checks every pinned digest against
gradle.org.

- a case with `expect-error.txt` must fail with a message carrying that clause
- a case with `expected/` must match every file in it, byte for byte
- a case with `needs-tools` provisions roughly 330 MB and is skipped unless `DAUKLE_GRADLE_E2E=1`.
  **CI sets it on every runner**: a run that skipped them proved only that bad input is refused
- a case with `expect-file.txt` names one path per line that the TOOL must have produced. The text of
  a generated file proves what daukle wrote; only a file Gradle made proves Gradle read it
- a `needs-tools` case asserts **compiled classes**, and the JUnit XML as well when its task is
  `gradle:test`
- every `needs-tools` case, example included, asserts that no `build.gradle`, `settings.gradle`,
  `.gradle` or `gradlew` reached the project root

```sh
DAUKLE=/path/to/daukle DAUKLE_GRADLE_E2E=1 sh test/cases.sh
```

### What is proved by mutation rather than asserted

| mutation | result |
| --- | --- |
| `ROOT` from `../../..` to `../..` | both e2e cases red: **0 classes compiled, and Gradle still exits 0**. This is the silent failure the output assertions exist for |
| `refuse_a_missing_launcher` returns early | `refuses-a-test-engine-with-no-launcher` goes green, and the resulting build would fail on the next Gradle major |
| drop the `buildscript` block | both plugin cases red: `Plugin with id '...' not found`, which is the negative control for the whole acquisition route |
| the `file` marker renders a bare `file(...)` | the marker case's text expectation differs |
| `refuse_a_version_no_pin_carries` returns early | `refuses-a-plugin-version-no-pin-carries` gets a success where it wanted a failure |
| `marker_of` stops refusing a mixed table | `refuses-a-marker-mixed-with-other-keys` goes green |
| `REFUSED_ENV` emptied | `refuses-daukles-own-token-in-a-build-file` goes green |
| **the `env` marker renders `''`, AND the text expectation is regenerated from that run** | the diff passes, because the expectation now encodes the bug, and **only `expect-file.txt` fails**: Gradle produced `.jar` rather than `marker-probe.jar`. That is what the second assertion is for |

### One bug this suite found that reading did not

`refuse_a_missing_launcher` never fired at all on the first run. The pattern was built by
concatenating the artifact name, and **a bare `-` in a Lua pattern is a lazy quantifier, not a
literal**, so `junit-platform-engine` never matched its own name. The artifact is escaped with
`gsub("(%W)", "%%%1")` now. A refusal that silently never refuses is the shape this repository is
most at risk from, because every other case stays green.

## Conventions this repository is held to

**Every error carries a `plugin.lua:<line>:` prefix.** Lua's `error()` adds it unless the message is
raised at level 0, and this plugin raises at level 0 for every message a user is meant to act on. A
test asserting on a message must assert on a clause, never on a token that could also appear in the
file path the message echoes.
