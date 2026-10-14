# gradle-included-build

A Gradle plugin built from source in this repository and applied to the project, through Gradle's
composite builds, with **no `build.gradle`, no `settings.gradle` and no wrapper anywhere in the
project**. `build-logic` is an included build that contributes the project plugin `example.hello`,
and the task that plugin registers runs as a daukle task.

```console
$ daukle gradle:hello
provisioning gradle 9.6.0
hello from build-logic, applied to example-gradle-included-build
```

That line is printed by a class compiled from `build-logic/src/main/java` in the same Gradle run,
so it is evidence that the build was included, built, and its plugin applied by id.

**This example needs `daukle/gradle` 1.9.0.**

## What to look at

**`[toolchains.gradle.builds."build-logic"]` describes the included build**, and the key is its
directory, with `/` between components, exactly as a module name is. Its sources default to
`build-logic/src/main/java`. Declaring `gradlePlugins` makes it a PLUGIN build: daukle writes
`pluginManagement { includeBuild('included/build-logic') }` into the generated `settings.gradle` and
a `gradlePlugin {}` block into the included build's own generated file. Nothing is written into
`build-logic/` itself.

**The `plugins` entry has no `version`**, and that is how it says the plugin comes from an included
build rather than from a pinned jar. It must name an id some build declares in `gradlePlugins`. It
renders as `id 'example.hello'` inside the project's `plugins {}` block, not as `apply plugin:`,
because Gradle finds a plugin from an included build only through `plugins {}`.

**`tasks = ["hello"]`** surfaces the task the plugin registers as `daukle gradle:hello`, the same
way a task from a third-party plugin is surfaced.

## What this example cannot show

**A library build.** A build with no `gradlePlugins` is included at the top level instead, and a
project or a module depends on it with `requiresBuilds = ["<name>"]`. The plugin's own cases run
one; this example keeps to the plugin half, which is the one a `build-logic` directory is for.

**A pinned jar inside the build.** A build block takes `classpath` and every other dependency key a
module takes, but `daukle/maven` cannot write into it yet, so its pins go inline or come from
`daukle.lua`.
