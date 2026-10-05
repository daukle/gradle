# gradle

The Gradle toolchain for daukle. It generates the build file Gradle reads into the derived directory, provisions Gradle and a JDK, and runs Gradle against daukle-pinned dependencies, so a project holds no build.gradle, no settings.gradle and no wrapper.

## Examples

- [`gradle-hello-no-build-file`](examples/gradle-hello-no-build-file): A Gradle project with no Gradle in it.

## What this plugin is

A `daukle.toolchain` named `gradle`. It **generates the build file Gradle reads**, provisions Gradle
and a JDK, and runs Gradle against the generated project. Your repository holds `daukle.toml` and
sources, and no `build.gradle`, no `settings.gradle`, no `gradlew` and no
`gradle/wrapper/gradle-wrapper.properties`.

**It replaced the dependency writer that used to live here**, which edited a `build.gradle` you
owned and needed Gradle already installed. That is the transparent-passthrough shape daukle exists
to remove: the TOOL should become invisible, not the plugin.

## Gradle resolves nothing

The generated build declares **no repository at all**. Every dependency is an absolute path to an
artifact daukle already fetched and verified by sha256, written by `daukle/maven`. Gradle is handed
files and never a coordinate, so there is no second resolver in the system and no chance of two
answers.

`--offline` is passed as well. It is not required, because with no repository and only file
dependencies there is nothing to fetch; it turns "Gradle happens not to reach the network" into
"Gradle may not".

## What it is worth, measured

Against `intisy/libs/java-utils`, a real library with twenty resolved dependencies:

| | |
| --- | --- |
| files at the project root | **`daukle.toml` and `daukle.lua`** |
| `gradle:classes` | **39 class files, equal to Gradle's own build of the same sources** |
| `gradle:test` | **6 tests, 0 failures**, equal to Gradle's own and to `daukle/java`'s |
| Gradle versions | **8.13 and 9.6.0, both green**, and the suite runs on both |
| installed Gradle | none. Nor an installed JDK |

Everything Gradle produces, including its own `.gradle/` state directory, lands under
`build/daukle/gradle/`. The project root is never written to, which the suite asserts rather than
assumes.

## Gradle 9 removed something nobody declares

A generated build using `useJUnitPlatform()` with file dependencies passes on Gradle 8.13 with a
deprecation and **fails outright on 9.6.0**: *"Failed to load JUnit Platform ... including the JUnit
Platform launcher"*. Gradle 8 injected `junit-platform-launcher` by itself and 9 stopped.

**It is in no POM, so no resolver produces it.** This plugin **refuses** a test run whose classpath
carries a platform engine without a matching launcher, and the message names the coordinate and the
version to add:

```
the test classpath carries junit-platform-engine 1.10.1 and no junit-platform-launcher.
Gradle 8 used to supply one and Gradle 9 does not, so this build would pass here and fail on
the next Gradle major. It is in no POM, so no resolver finds it: add
"org.junit.platform:junit-platform-launcher:1.10.1" to the test coordinates your resolver
reads, at the SAME version as the engine
```

**The plugin pins no launcher of its own**, deliberately. A 1.14.4 launcher against a 1.10.1 engine
dies with `NoClassDefFoundError: org/junit/platform/engine/OutputDirectoryCreator`, so a launcher is
not forward compatible with an older engine and one pinned default would be wrong for every project
not on that exact platform. The version is read off the engine you already resolved.

## What it does not do

- **A project with real build logic.** The generated build applies `plugins { id 'java' }` and
  nothing else, so a third-party Gradle plugin, a shared preset or a custom task does not survive.
  A third-party plugin would need a `repositories {}` for itself, which reopens everything above.
- **A raw Groovy escape hatch**, refused by name. It would readmit `build.gradle` through the back
  door with you editing Groovy inside a TOML string. `daukle`'s project-level `run = { tool, args }`
  is the escape hatch this project already decided on.
- **A multi-project build.** `settings.gradle` names one root project.
- **`online-gradle`** and anything else that fetches build logic at configure time. Every
  acquisition in daukle is pinned by sha256; a build that differs an hour later is the one feature
  where "impossible" is the right answer rather than a gap.

## License

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
