# gradle-fat-jar

An executable jar with every dependency inside it, from a project holding `daukle.toml` and
`src/main/java/` and **no `build.gradle`, no `settings.gradle` and no wrapper**. A real packaging
plugin from the Gradle Plugin Portal does the packaging, applied from a jar daukle pinned by
sha256, and **the generated build declares no `repositories {}` at all**.

```console
$ daukle gradle:run-shadow
Hello from a fat jar
```

That line is printed by `org.apache.commons.lang3.StringUtils`, which is **inside the jar being
run**, so the output is evidence that the dependency was bundled and not merely downloaded.

| task | what it does |
| --- | --- |
| `daukle gradle:shadow-jar` | writes `build/daukle/gradle/build/libs/example-gradle-fat-jar-all.jar` |
| `daukle gradle:run-shadow` | runs that jar |
| `daukle gradle:jar` | the ordinary jar, with no dependency in it |
| `daukle maven:resolve --resolve` | rewrites `daukle/maven/classpath.lua` from the coordinates |

## What to look at

**Nothing here knows what a fat jar is.** `daukle/gradle` has no fat-jar feature: `shadowJar` is a
task a third-party plugin contributes, named in `tasks`, and the plugin is acquired exactly as a
compile dependency is. That is the whole design, and it is why a different packaging plugin needs
no change to daukle.

**`main` applies Gradle's `application` plugin, and that is what makes the jar runnable.** A
packaging plugin reads `Main-Class` from the `application` extension, so without it the jar is
built correctly and has no entry point, and `java -jar` on it fails with "no main manifest
attribute". Setting the manifest by hand from `configure` is not possible here, because
`attributes(...)` is a method taking a map and this surface is data.

**The relocation is two properties, and the names matter.** `enableAutoRelocation` moves every
bundled package under `relocationPrefix`, so a library this jar carries cannot collide with a
different version of the same library in whatever loads it. Shadow 8.x spelled the first one
`enableRelocation`, and shadow 9 answers that with `Could not set unknown property`. Shadow's other
spelling, `relocate 'from', 'to'`, is a method call and is **not** expressible: this plugin renders
blocks and assignments and no Groovy.

**`daukle/maven/classpath.lua` is committed, and that is the shape rather than a shortcut.** It
holds **twenty pinned entries**: the one coordinate this project compiles against, and the
**nineteen modules** the shadow plugin itself needs in order to exist. Every url has a sha256 that
daukle computed by fetching and hashing the jar, because Maven Central publishes none. `daukle.lua`
includes the file, which is how generated data stays out of the manifest you wrote.

## The order matters the first time, and the refusal cannot be followed

A manifest declaring `[[toolchains.gradle.plugins]]` while `pluginClasspath` is empty is refused,
and **every command generates**, so even `maven:resolve` is refused. The message is right and
cannot be obeyed in that order. Starting from nothing, it is three steps:

1. declare the `[[toolchains.maven.resolve]]` block with **no** `[[toolchains.gradle.plugins]]`
   block, and run `daukle maven:resolve --resolve`;
2. add `daukle.include("daukle/maven/classpath.lua")` to `daukle.lua`, which has to be second
   because `include` raises on a file that is not there;
3. add the `plugins` block.

This example is committed at the end of that sequence, so copying it and changing a coordinate only
needs step 1 again.

## What this example cannot show

**A jar whose `Main-Class` was asserted by reading the manifest.** A zip stores its entry NAMES
uncompressed but its entry CONTENTS deflated, so the manifest inside this jar is not greppable. The
proof that the entry point is there is that the jar RUNS, which is what the console block above is.

**`minimize`.** Shadow can drop classes no code reaches, and nothing here uses it: it is
reachability analysis over a closure, which shadow should do and daukle should not.

**Two plugins applied at once.** Gradle resolves nothing in a generated build, so if two plugin
closures disagreed about a version the winner would be whichever jar path was emitted first, and
nothing currently decides that. One plugin is applied here and the question is open.

**A Maven project.** Everything here is Gradle. `daukle/maven` resolves coordinates; it does not
build.

**A multi-project build.** The generated `settings.gradle` names one root project and nothing here
answers an `include ':app'`.

## The one file that is a harness input rather than part of the example

`needs-tools` marks this example as one that provisions real tools, which the harness skips unless
`DAUKLE_EXAMPLE_E2E=1` is set. CI sets it on every runner. The `console` block above is
**executed** rather than decorative: its `$ ` line is run and the line beneath it must appear in
the output.

## The first run is slow

A Gradle distribution, a JDK and twenty jars, with no progress reported while they download. All of
it is cached per digest afterwards and shared by every project on the machine that pins the same
things.
