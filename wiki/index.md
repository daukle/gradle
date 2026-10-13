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
| `version` | which Gradle to provision, defaulting to `8.13`. Sixteen are pinned, `7.6.4` to `9.6.0`, and one it does not pin is refused by name with the whole list. `7.6.4` is the floor, and asking for less says why: `6.7` cannot run on the oldest JDK available here, and the versions in between are pinnable and nobody has asked |
| `jdk` | which JDK, through `daukle/java`'s table, defaulting to `17` |
| `release` | the Java source and target level |
| `main` | the class `gradle:run` runs. It also applies Gradle's `application` plugin, which is where a packaging plugin reads `Main-Class` from |
| `sourceRoot`, `resourceRoot`, `testSourceRoot`, `testResourceRoot` | the usual defaults |
| `classpath`, `testClasspath` | pinned entries, normally written by `daukle/maven`, rendering `implementation` and `testImplementation` |
| `compileOnly`, `runtimeOnly`, `testCompileOnly`, `testRuntimeOnly` | the Gradle configurations of the same names. **`compileOnly` is not on the runtime classpath and `runtimeOnly` is not on the compile classpath**, which is why they are separate keys rather than one |
| `annotationProcessor`, `testAnnotationProcessor` | javac's `-processorpath`, which is not the compile classpath. A processor usually wants its annotations on `compileOnly` too, and naming the same jar in both is correct |
| `api`, `compileOnlyApi` | the two configurations `java-library` provides. Declaring either switches that file to `java-library`, **for that module alone**. `api` is carried to a module that `requires` this one; `classpath` is not |
| `plugins` | third-party Gradle plugins to apply, each a `{ id, version }` |
| `pluginClasspath` | the pinned jars those plugins are applied FROM, normally written by `daukle/maven` |
| `configure` | one block per extension a plugin registers |
| `settingsPlugins`, `settingsPluginClasspath`, `settingsConfigure` | the same three for plugins applied to `Settings`, such as a toolchain resolver convention. The classpath is normally written by `daukle/maven` with `into = "settingsPluginClasspath"` |
| `tasks` | Gradle task names to surface as daukle tasks. `gradle:discover` tells you which exist |
| `modules` | per-module blocks, keyed by a name `[modules]` declares. A source root, `main` and **every dependency configuration above** belong here once a project has modules |

## Tasks

`gradle:classes`, `gradle:test`, `gradle:jar`, `gradle:run`, `gradle:version` and
`gradle:discover`, plus one for every name in `tasks`: `shadowJar` becomes `gradle:shadow-jar`.

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

## A fat jar, with no repository and no Gradle

A third-party packaging plugin is applied from a jar daukle pinned, so a fat jar needs no new
mechanism and no `repositories {}`:

```toml
[[toolchains.maven.resolve]]
repository  = "https://plugins.gradle.org/m2"
for         = "gradle"
into        = "pluginClasspath"
coordinates = ["com.gradleup.shadow:shadow-gradle-plugin:9.3.2"]

[toolchains.gradle]
main  = "com.example.Main"
tasks = ["shadowJar"]

[[toolchains.gradle.plugins]]
id      = "com.gradleup.shadow"
version = "9.3.2"

[toolchains.gradle.configure.shadowJar]
enableAutoRelocation = true
relocationPrefix     = "com.example.shaded"
```

`daukle gradle:shadow-jar` then writes a jar carrying your classes, every dependency's classes
relocated under that prefix, and a `Main-Class` the `application` plugin supplied, which `java -jar`
runs. `maven:resolve` must run **before** the `plugins` block is added, because a plugin is applied
from a pinned jar and there is nothing to apply until one exists.

## Several modules, one depending on another

`[modules]` is declared at the top level, because it is what a consumer resolves rather than
anything a toolchain owns. Declaring one makes daukle write a `settings.gradle` including every
module and a build file for each:

```toml
[modules.greeting]

[modules.app]
requires = ["greeting"]

[toolchains.gradle]
version = "8.13"

[toolchains.gradle.modules.app]
main = "com.example.App"
```

`daukle gradle:run` compiles `greeting` first, puts it on `app`'s compile classpath as
`implementation project(':greeting')` and runs `app`. A module name is its directory, with `/`
between components: `[modules."tools/core"]` is Gradle's `:tools:core`, and a name written with
`:` is refused with the `/` form to use instead. A module needs no toolchain block at all
unless it overrides something: its sources default to `<name>/src/main/java` and its tests to
`<name>/src/test/java`. Once a project declares modules, `main`, a source root and a classpath
belong to a module and are **refused project-wide**, because applying them to every module at once
is the silent version. Two modules declaring `main` is refused by name, and so is a `requires`
naming no module, two modules requiring each other, or a module requiring itself.

**This needs daukle 0.7.0.** An older daukle does not publish the module list to a plugin at all,
so the plugin refuses rather than quietly building only the root.

## What it does not do

Build logic written as CODE is not modellable: a task with a body, a `tasks.withType(...)` that
computes something, an `if` over a project property. A third-party plugin, a shared preset and an
extension block are all fine, because each of those is data. A raw Groovy escape hatch is
**refused by name**, because it readmits `build.gradle` through the back door with you editing
Groovy inside a TOML string.

`includeBuild`, which is a composite build rather than a multi-project one, is not modelled, and a
module's plugins and `configure` tree are the project's rather than its own.
