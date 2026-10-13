# gradle-multi-project

Two modules, one depending on the other, compiled and run through a provisioned Gradle with **no
`build.gradle`, no `settings.gradle` and no wrapper anywhere in the project**. The whole build is
eight lines of `daukle.toml`: `[modules.greeting]`, `[modules.app]` with `requires`, and the main
class. daukle writes the `settings.gradle` that includes both and a build file per module.

```console
$ daukle gradle:run
provisioning gradle 8.13
hello from the library module
```

That line is printed by `com.example.App` and produced by `com.example.Greeter`, which lives in the
OTHER module. So the output is evidence that `requires = ["greeting"]` became a real
`implementation project(':greeting')` and not just a line in a file.

| task | what it does |
| --- | --- |
| `daukle gradle:classes` | compiles both modules |
| `daukle gradle:run` | runs `app`, the one module declaring `main` |
| `daukle gradle:test` | compiles and runs each module's tests, neither of which has any here |

**This example needs daukle 0.7.0.** A module list reaches a plugin only from that version, and an
older daukle ignores `[modules]` without saying so, which is why the plugin refuses by name rather
than building the wrong thing. There is no mechanism for a plugin to declare a core version, so
this sentence is the mechanism.

## What to look at

**`requires` is the only edge you write, and the direction is the one you mean.** `app` requires
`greeting`, so `greeting` compiles first and lands on `app`'s compile classpath. Gradle is told
this as `implementation project(':greeting')` inside `app`'s generated build file; nothing in
`daukle.toml` names a path, a project accessor or a configuration.

**A module declaring `main` is how `gradle:run` stops being ambiguous.** `[toolchains.gradle.modules.app]`
carries `main = "com.example.App"`, and that block is what makes `app` the module `gradle:run`
runs. Two modules declaring `main` is refused by name, because the alternative is picking one and
being right half the time.

**Project-wide keys are rendered per module, not as `allprojects {}`.** A key under
`[toolchains.gradle]` applies to every module by being written into every module's build file.
That is more bytes and it is the only version that stays a deterministic function of the manifest:
`allprojects {}` would also reach the root project, which compiles nothing and would gain a Java
plugin and a source set it has no sources for.

**The derived root carries a build file that compiles nothing.** It exists to hold a buildscript
classpath when there is one, and it is written on EVERY run, header-only when there is not. The
reason is a migration this feature invites: a single-project project that has been built once
already has a full build file at that path, and adding `[modules]` would otherwise leave it in
place as the root project, compiling everything a second time at exit 0.

**Paths are one level deeper than a single-project build for a flat module like these two**, which
is why the generated redirect is four levels rather than three; a nested module climbs one more per
component, which `gradle-nested-modules` shows. Module output lands at
`build/daukle/gradle/<module>/build/classes/java/main/`, and `{ file = ... }` markers in a module's
build file resolve against the project root regardless.

## What this example cannot show

**`includeBuild`, which is a composite build and not a multi-project one.** Gradle treats the two
as different mechanisms, and nothing in `[modules]` reaches the first.

**A third-party plugin applied to one module rather than to all of them.** The buildscript
classpath lives on the derived root and the apply lines are rendered into every module, so
`gradle-third-party-plugin`'s shape composes with this one only in the all-modules direction.

**Per-module `daukle/maven` resolution.** One `classpath.lua` is resolved for the project and every
module sees it. Two modules wanting different versions of the same dependency is not expressible,
and Gradle resolves nothing here, so nothing would arbitrate it.

**A second module declaring `main`.** It is refused rather than shown, so what this example proves
about that case is only that the refusal names both modules.

**A longer `requires` cycle.** Two modules requiring each other is refused from the manifest;
three or more is left to Gradle, which fails at task-graph build with *"Circular dependency between
the following tasks"* and names them. Catching it here would mean a graph walk to reproduce a
diagnostic that already exists.

## The one file that is a harness input rather than part of the example

`needs-tools` marks this example as one that provisions real tools, which the harness skips unless
`DAUKLE_EXAMPLE_E2E=1` is set. CI sets it on every runner. The `console` block above is **executed**
rather than decorative: each `$ ` line is run and the lines beneath it must appear in the output.

## The first run is slow

Roughly 330 MB: a 137 MB Gradle distribution and a JDK of about 190 MB. Both are cached per digest
afterwards and shared by every project on the machine that pins the same ones.
