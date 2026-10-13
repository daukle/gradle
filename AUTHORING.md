# Authoring notes

`plugin.lua` plus `lib/` is the whole plugin. It is published as a release asset, one uncompressed
tar of the four files, and acquired by a `[plugins]` entry naming `daukle/gradle@<range>`.

It declares `uses = { "provision", "artifact", "exec", "write", "read", "parse" }`,
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
daukle gradle:discover           # what your applied plugins contribute
```

## Keys

| key | meaning |
| --- | --- |
| `version` | which Gradle to provision. Defaults to `8.13`. Pinned: **`7.6.4`, `8.4`, `8.8`, `8.10`, `8.10.2`, `8.11.1`, `8.13`, `8.14`, `8.14.3`, `8.14.4`, `9.0.0`, `9.1.0`, `9.2.0`, `9.3.1`, `9.5.0`, `9.6.0`**, and a version not in that set is refused by name rather than fetched. **`7.6.4` is the floor and the refusal says why**: `6.7` cannot run on JDK 17, and 7.3 to 7.6.3 are pinnable and unmeasured |
| `jdk` | which JDK to provision, through `daukle/java`'s table. Defaults to `17` |
| `sourceRoot` | defaults to `src/main/java` |
| `resourceRoot` | defaults to `src/main/resources` |
| `testSourceRoot` | defaults to `src/test/java` |
| `testResourceRoot` | defaults to `src/test/resources` |
| `release` | Java source and target level, e.g. `"8"` |
| `main` | the class `gradle:run` runs, and the reason `application` is applied |
| `classpath`, `testClasspath` | pinned entries, normally written by `daukle/maven`. They render `implementation` and `testImplementation`, and they keep these names rather than the configuration's because they are released |
| `compileOnly`, `runtimeOnly` | pinned entries rendering the Gradle configuration of the same name. `compileOnly` is **not** on the runtime classpath and `runtimeOnly` is **not** on the compile classpath, which is the whole reason they are separate keys |
| `testCompileOnly`, `testRuntimeOnly` | the same two for tests. **A JUnit launcher belongs in `testRuntimeOnly`**, which is where Gradle's own documentation puts it, and the launcher check looks there |
| `annotationProcessor`, `testAnnotationProcessor` | pinned entries for javac's `-processorpath`, which is a different path from the compile classpath. A processor normally wants its annotations on `compileOnly` as well, and **declaring the same jar in both keys is correct rather than redundant**: with the `annotationProcessor` block deleted and `compileOnly` left alone, lombok's generated method is simply absent and the build fails on it |
| `api`, `compileOnlyApi` | the two configurations **`java-library`** provides. Declaring either switches that file's base plugin from `java` to `java-library`, **for that module alone**, because `java-library` splits `compileClasspath` and applying it everywhere would change what compiles for projects that never asked. `api` is carried to a module that `requires` this one; `classpath` is not |
| `plugins` | a list of `{ id, version }`, one `apply plugin:` line each |
| `pluginClasspath` | pinned entries the plugins are applied FROM, normally written by `daukle/maven` into its own resolution |
| `configure` | a free-form tree, one Groovy block per extension |
| `tasks` | Gradle task names to surface as daukle tasks, one each. `gradle:discover` tells you which exist |
| `modules` | per-module blocks, keyed by a name `[modules]` declares. Exactly `sourceRoot`, `resourceRoot`, `testSourceRoot`, `testResourceRoot`, `main` and **every dependency configuration key above**, and when the project declares modules these are REFUSED project-wide rather than applied to all of them |

## The tasks a plugin contributes

`plugin.lua` declares five tasks of its own and a Gradle plugin contributes its own. **The two
halves are kept apart**, because only one of them needs Gradle:

```sh
daukle gradle:discover    # runs Gradle twice, writes build/daukle/gradle/discovered.txt
```

```toml
[toolchains.gradle]
tasks = ["publishGithub"]   # now `daukle gradle:publish-github` runs it
```

**`gradle:discover` REPORTS and nothing reads it back.** It renders the build file twice, once with
the apply lines and once without, runs a generated `daukleTasks` task in each, and the difference is
what the plugins added. The baseline is **this project with its apply lines removed**, not a bare
project elsewhere: same source sets, same dependencies, same Gradle, so the difference is the
plugins and not whatever two projects happen to differ by. It is also **computed every time**,
because Gradle's own task set differs between majors and a stored baseline is a number that gets
incremented.

**It is not run automatically.** It provisions and runs Gradle twice, and a `daukle tasks` that did
that would make listing tasks the slowest command in the tool. Same reason `maven:resolve` needs
`--resolve`.

### Why `tasks` is written by hand, and why the spec's committed file is not here

The design this implements wanted `gradle:discover` to write a committed `daukle/gradle/tasks.toml`
that the chunk read back. **That deadlocks, measured 2026-10-07.** A chunk cannot read a file
conditionally: there is no `pcall` in the sandbox and `daukle.read` raises on a file that is not
there, so a project that declared plugins failed **every** command until its first discovery,
including the discovery itself. The error was the raw `cannot open ".../tasks.toml"` with a Lua
traceback.

Reading the names out of `daukle.toml` instead has no such moment, and it is better on two counts
the spec did not weigh: the project carries **one** committed file instead of two, which is the
file-location rule's third clause, and a project surfaces the plugin tasks it actually uses rather
than all of them. `gradle:discover` is then exactly what `maven:list` is to a coordinate: a report
into the derived directory that a human acts on.

### The mapping is lossy, and not in the way the spec said

camelCase to kebab, lowercased: `publishGithub` becomes `publish-github` and
`processGitHubResources` becomes `process-git-hub-resources`, which is ugly and correct. Inventing
an acronym rule would be per-plugin knowledge in the one place this design refuses it.

**The spec said `publishGithub` and `publishgithub` collide. They do not**: the hyphen is inserted
only at a lowercase-to-uppercase boundary, so the second stays `publishgithub`. The real collision
is `publishGithub` against a Gradle task literally named `publish-github`, and that pair is refused
by name, as is any mapped name equal to one of `classes`, `test`, `jar`, `run`, `version` or
`discover`. A duplicate task name is fatal on **every** command in a project, so it is refused where
the name is read rather than where it is used.

## `version` lives in TWO places, and reading one of them shipped the wrong Gradle

**Core builds the config a callback sees differently for a generate callback and for a task.** For
`generate` it drops `dependencies` and keeps `version`, because a generated file may legitimately
depend on the requested version. For a TASK it drops **both** and exposes the value as
`context.toolchain.version` instead. `src/config/config_dispatch.c` does both and says so.

So `config_of(context).version` is a string at generate time and `nil` in every task, and
`distributions.for_version(nil)` answers the DEFAULT. That is `D-115`: every task in this plugin ran
Gradle 8.13 whatever the manifest said, through a released `1.2.0`. `gradle_version_of(context)`
reads both places, which is the idiom `java`, `c`, `node` and `cmake` already had.

**Nothing caught it because the version reaches generate**, so an unpinned version was still refused
by name, and because every fixture but two declared `8.13`, which is also the default. The two that
did not were the cases named after Gradle 9. **`expect-output.txt` is the check that was missing**:
one literal per line that the run's own output must carry, and `provisioning gradle <v>` is the only
line that names the Gradle that ran. `jdk` is unaffected: core reserves `version` and
`dependencies` and passes every other key through both callbacks.

## A fat jar is an ADOPTION, and `main` is what makes it runnable

**`D-114`. Nothing here knows what a fat jar is**, and that is the point: a packaging plugin is a
third-party plugin like any other, so `daukle/maven` resolves shadow's 19-module closure into
`pluginClasspath`, `plugins` applies it and `tasks = ["shadowJar"]` surfaces it as
`gradle:shadow-jar`. **`shadowJar` decides what to bundle from `files(...)` paths**, which was the
one thing expected to fail, and the generated build still declares no repository.

**`main` applies `application` as well as `java`, and that is not cosmetic.** Shadow reads
`Main-Class` from the application EXTENSION, so a build applying only `java` produced a fat jar with
no entry point. Setting it from `configure` instead is not expressible: `manifest { attributes(...) }`
is a method taking a MAP and the renderer emits blocks and assignments. Applying `application` is a
block of generator and gives shadow somewhere to read from, and **7 of the 62 shadow users in this
tree set `Main-Class` by hand anyway**, so the map problem is real for them regardless.

**`daukleRun` is kept beside the `run` that `application` contributes.** `gradle:run` is a published
surface two examples exercise, and a task this plugin registers cannot be renamed by a plugin the
project applies.

**A relocation is expressible and the obvious spelling is not.** `relocate 'a', 'b'` is a
two-argument method; `enableAutoRelocation` and `relocationPrefix` are Gradle `Property` types and
render as assignments. Shadow 8.x called the first `enableRelocation`, which 9.3.2 answers with
"Could not set unknown property", so **read a property name out of the pinned jar with `javap`**
rather than from a tutorial.

**The case asserts the jar's CONTENTS, through `expect-contains.txt`.** A zip stores entry names
uncompressed, so a relocated name is greppable with no `unzip` on the runner; contents are deflated,
which is why `Main-Class` is proved by RUNNING the jar. **Measured as necessary rather than assumed:
dropping the relocation leaves a build that exits 0 and a jar that still runs and still prints the
expected line**, so output alone catches nothing and only the jar assertion reddens.

## `daukle tasks` does not run generate-time validation

A manifest `daukle check` refuses still LISTS its tasks: a `plugins` entry with a version no pin
carries lists nine tasks happily. That reads like a validation hole and is not one. `tasks` is a
listing; the check belongs to generate, and `check` and `sync` both refuse with the right message.

## Three phases to a first build, and the refusal cannot be followed in order

A manifest that declares `[[toolchains.gradle.plugins]]` while `pluginClasspath` is empty is refused
at generate time, and **every command generates**, so even `maven:resolve` is refused. The working
sequence is: resolve with no `plugins` block; add the `daukle.include`, which must be second because
`include` raises on a file that is not there; then add the `plugins` block. Nothing is
unrecoverable. Recorded in `D-114`.

**Both refusals now NAME that order**, which is `D-118` and the reason this section no longer says
the advice cannot be followed. They also say why: *"this check runs on every command, so
`maven:resolve` cannot fix it in place"*. **There are two of them and they differ**, because the
recovery does: an empty `pluginClasspath` means resolve with no `plugins` block at all, while a
version no pinned entry carries, the shape a SECOND plugin hits, means remove that one entry,
resolve, and put it back. A case asserts each ordering clause, and neither clause appears in the
other's message.

**The structural fix was NOT taken**, and `D-118` records why: moving the check out of `generate`
and into the task that writes the apply line would let `maven:resolve` run untouched, at the cost of
`daukle check` no longer catching an unpinned plugin, which is the thing `generate`-time rendering
exists for.

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

## A multi-project build

`[modules]` is core's surface, not this toolchain's, and declaring one switches the writer from one
build file to a `settings.gradle` that includes every module plus a build file each.

**The redirect is FOUR levels in a module file and three in a single-project one.** A module's
build file lives at `build/daukle/gradle/<name>/build.gradle`, one directory deeper than the
derived root, so its source roots are `new File(file('../../../..'), ...)`. The depth is threaded
rather than constant because a `{ file = ... }` marker takes the same prefix the source roots do: a
project-wide `configure` carrying the derived root's own depth resolved to `<repo>/build`, which is
the defect this cost before it was found.

**A module usually needs no toolchain block at all.** It defaults to `<name>/src/main/java`,
`<name>/src/main/resources`, `<name>/src/test/java` and `<name>/src/test/resources`, which is the
shape **117 of this tree's 185 subproject build files** rely on: they declare nothing and take the
convention.

**Project-wide keys are rendered into EVERY module rather than into `allprojects {}`.** The
duplication costs a reader nothing, because the renderer is the only writer, and it avoids a second
configuration mechanism to learn. `allprojects {}` would also reach the root project, which has no
sources and would gain a Java plugin and a source set for them.

**The root build file exists to hold the buildscript classpath, and it is written on every run.**
It was conditional first, and the measurement that changed it was the migration this feature
invites: a single-project project already built once has a full build file at that path, and adding
`[modules]` would leave it as the ROOT PROJECT of the new build, with its own source roots, its own
jar and a stale `daukleRun`, all at exit 0. **No case can catch that**, because the harness wipes
its sandbox per case and a two-run shape does not exist, so the file is written unconditionally and
carries only its header when there is no classpath.

**A two-module `requires` cycle is refused from the manifest; a longer one is Gradle's to name.**
Gradle fails at task-graph build with *"Circular dependency between the following tasks"* and names
them, so reproducing it here would mean a graph walk to re-derive a diagnostic that already exists.

**A module requiring ITSELF has its own refusal**, because one module is not two: the cycle check
would answer with the same name twice, which reads as a defect in the refusal rather than in the
manifest.

**`gradle:run` is refused when two modules declare `main`**, by name and naming both. The
alternative is picking one, which is right half the time and silent the other half.

**The launcher check runs per module, not once for the project.** A module carries its own
`testClasspath`, so a missing `junit-platform-launcher` is a property of one module and a single
project-wide check would pass on the strength of a sibling.

### What this does not cover

- **`gradle:discover` on a multi-project build.** Discovery renders the build file twice and
  diffs the task lists; nothing has measured what that reports when the names come from several
  modules at once.
- **`compileOnlyApi` is rendered and never exercised.** It shares every line of its path with `api`
  except its row in `lib/configurations.lua`, and no case declares one.
- **NESTED module names.** A `[modules]` key holding a `:` is refused, and this is the limit most
  likely to be met by a large real build rather than a hypothetical one. **Measured 2026-10-13**:
  the largest Gradle build in the tree this plugin was written against declares **34 modules, of
  which only 5 are flat** - 23 are at depth two and 6 at depth three. **A flat list serves 5 of its
  34.** That project also uses `includeBuild`, which this plugin does not model either.
- **The 34-module project**, which is that same one. Nothing has rendered it. **Neither core cap is
  what stops it**: `FR_GENERATE_MAX_FILES` bounds the table a generate callback returns and this
  plugin's generate returns exactly one file, `settings.gradle`, whatever the module count. A
  module's build file is TASK-written through `daukle.write`, which has no count cap. **So a
  60-module project would not meet the cap and neither would a 600-module one**; the remaining
  limit is the 512-byte path buffer in the write verb.
- **A module whose source directory does not exist**, which **cannot** be a refusal. `pcall` is in
  the sandbox's `REMOVED` list and `daukle.read` raises, so a plugin cannot probe a path without
  dying on the project that lacks it. The mitigation is that every multi-project case asserts a
  per-module output file, and a module that compiled nothing produces none.

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
Re-measured 2026-10-13 over the **158** `gradle-wrapper.properties` files under
`F:/Documents/GitHub` that are not in `archived` or `sandbox`: **16 distinct versions, 6.7 through
9.5.0**, with `9.3.1` (79) and `8.14` (50) dominating. **Pinning only the newest would have served
none of them**, because nothing in the tree declares `9.6.0`.

**Sixteen rows cover 157 of the 158**, and the one left is `6.7`. **It is not a missing digest and
pinning it would be a lie**: gradle.org publishes its `.sha256` like every other, and Gradle 6.7
then dies on `Unsupported class file major version 61` because its Groovy cannot read JDK 17 class
files and 17 is the oldest JDK `daukle/java` pins. So the floor belongs to the JDK table rather
than to this one, serving it means adding a JDK of 15 or less in the other plugin, and until then
the refusal says all of that rather than only listing what is pinned. Measured by running it,
2026-10-13.

**The refusal deliberately does NOT say "an older Gradle cannot run on JDK 17"**, which is false of
7.3 through 7.6.3: those run on 17 and are unpinned only because nothing in this tree declares one,
so they are pinnable and merely unmeasured. The first draft of this feature said the broader thing
and would have shipped a refusal that was wrong about four minor versions.

**Every other row was measured the same way rather than transcribed and hoped for**: eleven
versions were each run through the real compile-and-test case against a provisioned Gradle and JDK
before being pinned, and **a version that had failed would not have been pinned**. A row is a claim
that this plugin can drive that Gradle, and `D-115` is what an unasserted claim costs here.

**A row is a url and a digest, so rows are cheap and CI is not.** The e2e cases therefore run one
version at each EDGE of the range, `7.6.4` and `9.6.0`, which is not decoration: the same build that
works on 8 fails outright on 9 for want of a `junit-platform-launcher` that is in no POM graph.
A single-major suite would have shipped that. **The 8 line is still exercised** by the three other
cases that pin `8.13` and by every example, so moving the lower edge off it lost nothing.

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
| `discovery.contributed` returns the full list | the discovery report carries Gradle's own 34 tasks and differs |
| the baseline run is not bare | the difference is empty and the report differs |
| the registration loop iterates nothing | the three `tasks` refusal cases get a success where they wanted a failure |
| **the rendered marker is desynchronised from `discovery.MARKER`** | `gradle:discover` fails with *"Gradle printed no task names at all"*. Changing `discovery.MARKER` alone does NOT reproduce it, because the renderer is handed that same string rather than carrying a second copy, which is the point of passing it |

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
