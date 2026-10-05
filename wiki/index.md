# daukle/gradle

The Gradle toolchain. It **generates the build file Gradle reads**, provisions Gradle and a JDK,
and runs Gradle against the generated project. Your repository holds `daukle.toml` and sources, and
no `build.gradle`, no `settings.gradle`, no `gradlew` and no wrapper properties.

## Declaring it

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

## Keys

| key | meaning |
| --- | --- |
| `version` | which Gradle to provision, defaulting to `8.13` |
| `jdk` | which JDK, through `daukle/java`'s table, defaulting to `17` |
| `release` | the Java source and target level |
| `main` | the class `gradle:run` runs |
| `sourceRoot`, `resourceRoot`, `testSourceRoot`, `testResourceRoot` | the usual defaults |
| `classpath`, `testClasspath` | pinned entries, normally written by `daukle/maven` |

## Tasks

`gradle:classes`, `gradle:test`, `gradle:jar`, `gradle:run`, `gradle:version`.

## Gradle resolves nothing

The generated build declares **no repository at all**. Every dependency is an absolute path to an
artifact daukle already fetched and verified. Gradle is handed files and never a coordinate, so
there is no second resolver in the system and no chance of two answers.

Everything Gradle produces, including its own `.gradle/` state directory, lands under
`build/daukle/gradle/`. The project root is never written to.

## Gradle 9 removed something nobody declares

A generated build using `useJUnitPlatform()` with file dependencies passes on Gradle 8.13 with a
deprecation and **fails outright on 9.6.0**: Gradle 8 injected `junit-platform-launcher` by itself
and 9 stopped. It is in no POM, so no resolver produces it.

This plugin **refuses** a test run whose classpath carries a platform engine without a matching
launcher, and names the coordinate and the version to add. It pins no launcher of its own: a 1.14.4
launcher against a 1.10.1 engine dies outright, so a launcher is not forward compatible with an
older engine and one default would be wrong for every project not on that platform.

## What it does not do

A project with real build logic is not modellable: the generated build applies
`plugins { id 'java' }` and nothing else, so a third-party Gradle plugin, a shared preset or a
custom task does not survive. A raw Groovy escape hatch is **refused by name**, because it readmits
`build.gradle` through the back door with you editing Groovy inside a TOML string.
