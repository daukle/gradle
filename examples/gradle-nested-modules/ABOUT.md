# gradle-nested-modules

Four modules at three depths, compiled and run through a provisioned Gradle with **no
`build.gradle`, no `settings.gradle` and no wrapper anywhere in the project**. It is the shape of a
large real build: a flat `core`, two modules both called `core` under different parents, and a
module three directories deep that depends across all of them.

```console
$ daukle gradle:run
provisioning gradle 9.6.0
tools+core+interop
```

That line is assembled from three modules at three depths, so it is evidence that every
`requires` became a real project dependency and that every module's sources were found.

**This example needs `daukle/gradle` 1.7.0 and daukle 0.7.0.**

## What to look at

**A module name is its directory, with `/` between components.** `[modules."tools/maven/plugin"]`
is the module whose sources live in `tools/maven/plugin/src/main/java`, and daukle writes Gradle's
`include ':tools:maven:plugin'` for it. TOML needs the key quoted. A name written with Gradle's `:`
is refused, and the message says which `/` form to write instead.

**`tools` and `tools/maven` are not modules here, and that is fine.** Gradle makes each one an
implicit parent project. daukle writes each a build file that holds only its header, so nothing a
previous build left in that directory is ever read.

**Three modules produce a jar called `core.jar`**: `core`, `interop/core` and `tools/core`. Gradle
names a jar after the last component, the three land at three different paths, and all three sit on
the runtime classpath of `gradle:run` without colliding.

## What this example cannot show

**`includeBuild`, a composite build.** It is a different Gradle mechanism, and nothing in
`[modules]` reaches it.

**A project directory that differs from the module name.** Gradle lets `settings.gradle` move a
project anywhere; here the name IS the directory, which is what keeps one spelling for every
`requires`.
