# gradle-third-party-plugin

A Gradle project that applies a real third-party plugin from the Gradle Plugin Portal, configures it
from TOML and gains the task it contributes, **with no `build.gradle`, no wrapper and no
`repositories {}` anywhere**. `io.github.intisy.github-gradle` is the most applied plugin in the tree
this project was measured against: daukle pins its jar by sha256, puts it on the buildscript
classpath and writes `apply plugin:` into the build file it generates, so Gradle resolves nothing.

```console
$ daukle gradle:classes
BUILD SUCCESSFUL
$ daukle tasks
gradle:publish-github
```

| task | what it does |
| --- | --- |
| `daukle gradle:discover` | runs Gradle twice and reports which tasks the applied plugins contribute |
| `daukle gradle:publish-github` | runs the plugin's `publishGithub`, which this example does not do in CI |

## What to look at

**The generated build declares no `repositories {}` and the plugin still applies.** This was believed
to be impossible until 2026-10-06: a plugin applied through Gradle's own `plugins {}` block is
resolved by Gradle from the Portal, which is a dependency daukle did not pin. The route that keeps
the property is `buildscript { dependencies { classpath files('<pinned jar>') } }` plus
`apply plugin: '<id>'`, and a plugin marker is an ordinary Maven POM, so acquiring a plugin is
acquiring a coordinate like any other.

**Nothing in `daukle/gradle` knows what `publishGithub` is.** The `configure` tree becomes nested
Groovy by shape alone: a string, number or boolean is an assignment, a table is a block, and a TOML
array of tables is the same block repeated. That is why `[[toolchains.gradle.configure.publishGithub.artifacts.artifact]]`
comes out as `artifacts { artifact { ... } }` with no per-plugin code.

**`{ env = ... }` and `{ buildOutput = ... }` are markers, not strings.** A token may not be
committed and a `File` property will not coerce from a quoted string, so each is a one-key table
rather than a magic prefix a real value would one day collide with. `buildOutput` is relative to
Gradle's build directory and its sibling `file` is relative to your project root: a hand-written
build spelled both the same way, and daukle moved the project directory out from under them.

**`GITHUB_TOKEN` reaches Gradle because the plugin declares it.** daukle scrubs every credential it
knows from a child process unless the plugin asked for it by name, so the declaration is what turns
`System.getenv('GITHUB_TOKEN')` into a value rather than an empty string. `DAUKLE_TOKEN` is refused
outright: it is daukle's own credential and no build input.

**`tasks` is written by hand and `gradle:discover` is what tells you what to write.** Only running
Gradle can know which tasks a plugin's jar contributes, so discovery renders the build file twice,
once with the apply lines and once without, and reports the difference into
`build/daukle/gradle/discovered.txt`. Nothing reads that file back: the names you want go in
`daukle.toml`, which keeps the project to one committed file and surfaces the tasks you actually use.

## What this example cannot show

**`publishGithub` actually publishing.** The task is registered and `daukle tasks` lists it, and CI
runs `gradle:classes` instead, because running it would create a GitHub release every time the suite
ran. What the `classes` run does prove is that the plugin applied and that both `configure` blocks
were accepted: a plugin that was not applied fails `github {}` with `MissingMethodException`, and a
property the extension does not have fails with *"Could not set unknown property"*.

**The `daukle/maven` resolution that normally writes `pluginClasspath`.** The pinned jar is
hand-written here so that this stays an example of one plugin. A real project writes
`[[toolchains.maven.resolve]]` with the marker coordinate, `repository =
"https://plugins.gradle.org/m2"` and `into = "pluginClasspath"`, and never types a digest;
`AUTHORING.md` carries that shape.

**A `configure` block for an extension no applied plugin registers.** It is not caught when the file
is written and cannot be: the renderer holds no plugin knowledge, so it cannot know which extensions
a jar registers, and `configure.jar` or `configure.java` is legitimate with no plugin at all.
Gradle's own failure names the block.

**Build logic written as CODE**, which is the boundary that remains. A task with a body, a
`tasks.withType(...)` that computes something, an `if` over a project property: none of it is data.
The escape hatch this project decided on is a manifest task's `run = { tool, args }`, and a raw
Groovy block is refused by name.

**Two plugins applied at once**, and the version conflict their closures may have. Gradle resolves
nothing here, so the winner would be the `files(...)` order and nothing currently decides it.

**A multi-project build**, and any platform but the three CI runners.

## The one file that is a harness input rather than part of the example

`needs-tools` marks this example as one that provisions real tools, which the harness skips unless
`DAUKLE_EXAMPLE_E2E=1` is set. CI sets it on every runner. The `console` block above is **executed**
rather than decorative: each `$ ` line is run and the lines beneath it must appear in the output.

## The first run is slow

Roughly 370 MB: a 137 MB Gradle distribution, a JDK of about 190 MB, and the plugin's own 37 MB
shaded jar. All three are cached per digest afterwards and shared by every project on the machine
that pins the same ones.
