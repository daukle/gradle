# gradle-hello-no-build-file

A Gradle project with no Gradle in it. The repository holds `daukle.toml` and `src/main/java/` and
**no `build.gradle`, no `settings.gradle`, no `gradle.properties` and no wrapper**: daukle generates
the build file Gradle reads into `build/daukle/gradle/`, downloads a Gradle distribution and a JDK,
verifies both against digests the plugin pins, and runs Gradle with that directory as the project.

```console
$ daukle gradle:run
hello from gradle, with no build file
```

The other four tasks are the same shape and are not repeated in the block above, because only the
`console` block is executed and running a provisioned Gradle four more times would multiply the
runner cost for no new information:

| task | what it does |
| --- | --- |
| `daukle gradle:classes` | compiles only |
| `daukle gradle:jar` | packages `build/daukle/gradle/build/libs/example-...-no-build-file.jar` |
| `daukle gradle:version` | prints the version of the Gradle daukle provisioned |
| `daukle tasks` | lists the six tasks the plugin declares |

## What to look at

**Nothing Gradle writes reaches the project root**, which is the property the whole plugin exists
for. Gradle's own `.gradle/` state directory, its `build/` output and the generated build file all
land under `build/daukle/gradle/`, and the generated `sourceSets` block points back at the real
`src/` three levels up. The suite asserts that no `build.gradle`, `settings.gradle`, `.gradle` or
`gradlew` appears at the root rather than assuming it, because the redirect fails SILENTLY when its
path arithmetic is wrong: Gradle resolves the source roots against the wrong directory, finds
nothing, compiles nothing and exits 0.

**This example names a published coordinate, exactly as your own project would.** Nothing here
points at a working tree, so the directory can be copied anywhere and `daukle sync` works. That is
what the resolver and coordinate lines in `daukle.toml` are:

```toml
[resolvers.github]
url = "https://raw.githubusercontent.com/daukle/daukle/<commit>/plugins/github-releases.lua"
sha256 = "..."

[plugins]
gradle = { resolver = "github", coordinate = "daukle/gradle@^1.0.0" }
```

**The suite then runs it twice**, which is how it keeps both properties at once. The first run is
the example exactly as committed, against the published release, and it is the only thing in this
organization that checks a *published* plugin still works. The second stages this repository's
working tree over a copy and runs it again, so a break in the plugin as it stands now reddens this
repository's own CI rather than waiting for a release.

**`version` is Gradle's version and `jdk` is the JDK's, and both have a default.** This example pins
`version = "8.13"` because it also pins what it exercises; leaving it out gives the same 8.13, and
leaving `jdk` out gives 17. Neither default moves on its own: it moves with a release of the plugin,
so a given plugin version always provisions the same two tools. A version the plugin does not pin is
refused by name, because a version it does not pin is a version it cannot verify.

**`main` is a class name, not a path**, and it is what makes `gradle:run` exist: the generated build
registers a `JavaExec` task against `sourceSets.main.runtimeClasspath`. Leave it out and the other
four tasks still work.

**The generated build declares no `repositories {}` block at all, and that is the point rather than
an omission.** A dependency reaches Gradle as an absolute path into daukle's artifact cache, pinned
by sha256 before it got there, written by `daukle/maven`. Gradle resolves nothing, and the plugin
passes `--offline` so that a block which reintroduced a repository fails loudly instead of quietly
downloading.

## What this example cannot show

**A third-party Gradle plugin**, which this example declares none of so that it stays the smallest
thing that works. That is not a boundary: `gradle-third-party-plugin` beside this one applies a real
plugin from the Gradle Plugin Portal, configures it and runs a task it contributes. This page said
until 2026-10-07 that a third-party plugin needed a `repositories {}` of its own and so could never
work. **It does not**: it needs a pinned jar on the buildscript classpath, which `daukle/maven`
acquires like any other coordinate.

**Build logic written as CODE**, which is the boundary this plugin does deliberately not cross. A
task with a body, a `tasks.withType(...)` that computes something, an `if` over a project property:
none of it is data, and the renderer holds no Groovy. **A raw Groovy escape hatch is refused by
name**: `extra = """..."""` would be the shortest path to covering a real project and it readmits
`build.gradle` through the back door, with the user editing Groovy inside a TOML string. The escape
hatch this project decided on is a manifest task's `run = { tool, args }`.

**A multi-project build.** The generated `settings.gradle` names one root project and nothing here
says what an `include ':app'` tree would need.

**Dependencies and tests**, which this example declares none of so that it stays readable. The
plugin's own `test/cases/` carry both, on Gradle 8.13 and 9.6.0, and they are where the one rule
worth knowing lives: **Gradle 8 injected `junit-platform-launcher` into a test runtime and Gradle 9
does not**, and the launcher is in no POM graph, so no resolver produces it. A test classpath
carrying a JUnit platform engine with no launcher is refused here, at the version the engine already
resolved to, rather than passing on 8 and breaking at the next Gradle major.

**Gradle 7, `--no-daemon`, and a JUnit-4-only test tree**, none of which has been measured against
this plugin on any platform.

## The first run is slow

Roughly 330 MB: a 137 MB Gradle distribution and a JDK that is about 190 MB on Windows and varies by
platform, with no progress reported while they download. Both are cached per digest afterwards and
shared by every project on the machine that pins the same ones. The JDK comes from `daukle/java`'s
own pinned table rather than a second copy of it, so a project on both toolchains at the same `jdk`
downloads one JDK instead of two; the two plugins default to different majors, 17 here and 21 there,
so say which one you want if you use both.

## The one file that is a harness input rather than part of the example

`needs-tools` marks this example as one that provisions real tools, which the harness skips unless
`DAUKLE_EXAMPLE_E2E=1` is set. CI sets it on every runner. The `console` block above is **executed**
rather than decorative: its `$ ` line is run and the line beneath it must appear in the output, so
the command and its result cannot drift apart the way a separate expectation file did.

**There is no committed build output here, and nothing is missing.** `gradle:run` really does
compile and run the program; `build/` is gitignored, which is the only reason you cannot see the
result in the repository.
