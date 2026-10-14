--- daukle/gradle: a toolchain that owns the build file Gradle reads.
---
--- The user writes daukle.toml and sources. This generates settings.gradle and
--- build.gradle into the derived directory, provisions Gradle and a JDK, and
--- runs Gradle with --project-dir pointed there. The project root never carries
--- a build file, a settings file or a wrapper, which is the whole of what this
--- plugin is for: the TOOL becomes invisible, not the plugin. D-90.
---
--- Dependencies arrive as FILE PATHS into daukle's artifact cache, written by
--- daukle/maven, so the generated build declares no repository and Gradle
--- resolves nothing.

daukle.plugin{
  api = 1,
  uses = { "provision", "artifact", "exec", "write", "read", "parse" },
  exports = { "lib/distributions", "lib/build_file", "lib/junit", "lib/discovery", "lib/modules" },
  --[[ Core scrubs every credential it knows from a child it starts unless the
       plugin declares it, so an undeclared GITHUB_TOKEN would reach Gradle as
       unset and a generated `System.getenv(...) ?: ''` would hand the build an
       empty string with nothing saying why. 56 of this tree's 77 build files
       apply a plugin that takes one, which is what makes this the credential
       worth passing. DAUKLE_TOKEN is deliberately not here: see
       REFUSED_ENV in lib/extensions.lua. D-32. ]]
  env = { "GITHUB_TOKEN" },
  --[[ The JDK table is daukle/java's and is read rather than copied: a second
       copy drifts, and a project using both toolchains would download two
       JDKs. Measured before being relied on (D-90, G10): lib/jdks calls no
       verb at all, so the rule that a required module runs under the
       DEPENDENT's uses has nothing to cover. ]]
  requires = {
    java = {
      url = "https://github.com/daukle/java/releases/download/1.1.0/plugin.lua",
      sha256 = "45deb1bcb490cbd71553a2327f364afedb5e5719f91d0ab593cf3474427153b3",
    },
  },
}

local distributions = daukle.require("lib/distributions")
local build_file = daukle.require("lib/build_file")
local settings_file = daukle.require("lib/settings_file")
local discovery = daukle.require("lib/discovery")
local module_graph = daukle.require("lib/modules")
local validation = daukle.require("lib/validation")
local writer = daukle.require("lib/writer")

local SETTINGS_FILE = "settings.gradle"
local REPORT_FILE = "discovered.txt"

--[[ settings.gradle is generated and build.gradle is NOT, and the split is
     forced rather than chosen. A dependency line is an absolute path to a
     resolved artifact, daukle.artifact is refused inside generate, and the
     refusal says why: "generation is a pure function of the manifest". So the
     file that needs no acquisition is born here and the one that does is
     written by a task through daukle.write, which lands in the same derived
     directory. ]]
daukle.toolchain{
  name = "gradle",
  generate = function(context)
    local config = validation.config_of(context)
    validation.validated(context, config)
    local record = validation.composite_of(context, config)
    return { [SETTINGS_FILE] = settings_file.settings(validation.project_name(context),
                                                    module_graph.declared(context),
                                                    validation.settings_plugins_of(config, record.owners)
                                                    ~= nil,
                                                    record) }
  end,
}

--- @implNote the launcher jar rather than `bin/gradle`, because that is a POSIX
--- shell script and `bin/gradle.bat` a batch file, and neither is a program
--- daukle can start on every host. The jar is what both scripts eventually
--- exec. Starting it with the provisioned java is also what makes JAVA_HOME
--- unnecessary: Gradle reports the daemon JVM as "no JDK specified, using
--- current Java home", which is the one daukle provisioned.
local function run_gradle(context, config, arguments, options)
  local pick = distributions.for_version(validation.gradle_version_of(context))
  local jdk = validation.jdk_for(context, config)

  local gradle_root = daukle.provision{ url = pick.url, sha256 = pick.sha256,
                                        as = "gradle " .. pick.version }
  local jdk_root = daukle.provision{ url = jdk.url, sha256 = jdk.sha256,
                                     as = "temurin " .. validation.jdk_version_of(config) }

  local java = jdk_root:tool(jdk.home .. "/bin/java"
                             .. (context.host.os == "windows" and ".exe" or ""))
  local argv = {
    "-classpath", gradle_root:path(pick.home .. "/lib/gradle-launcher-" .. pick.version .. ".jar"),
    "org.gradle.launcher.GradleMain",
    --[[ "." because a task already runs with its working directory in the
         derived tree, which is how daukle/cmake gets away with "-S .". The
         redirect is still what keeps the project root clean: Gradle treats
         this directory as the project and writes its own .gradle/ and build/
         under it, and the generated sourceSets point back at the real tree. ]]
    "--project-dir", ".",
    --[[ Not required and kept anyway: with no repository and only file
         dependencies there is nothing for Gradle to fetch, so this turns
         "Gradle happens not to reach the network" into "Gradle may not". A
         generated block that reintroduced a repository fails loudly rather
         than quietly downloading. ]]
    "--offline",
  }
  for index = 1, #arguments do argv[#argv + 1] = arguments[index] end
  return daukle.exec(java, argv, options)
end

local function gradle_task(name, arguments)
  daukle.task{
    name = "gradle:" .. name,
    run = function(context)
      local config = validation.config_of(context)
      writer.write_build_file(context, config)
      run_gradle(context, config, arguments)
    end,
  }
end

gradle_task("classes", { "classes" })
gradle_task("test", { "test" })
gradle_task("jar", { "jar" })
gradle_task("run", { "daukleRun" })

daukle.task{
  name = "gradle:version",
  run = function(context)
    run_gradle(context, validation.config_of(context), { "--version" })
  end,
}

--- Every task name Gradle reports for one rendering of the build file.
local function task_names_of(context, config, options)
  writer.write_build_file(context, config, options)
  local result = run_gradle(context, config, { "daukleTasks", "--quiet" }, { capture = true })
  if result.truncated then
    error("Gradle's task list was truncated, so a discovery would record fewer tasks than the"
          .. " project has", 0)
  end
  return discovery.printed_names(result.stdout)
end

--[[ The one task here that learns something only Gradle knows, which is what
     `maven:list` is to a coordinate: it REPORTS, into the derived directory,
     and nothing it writes is committed or read back. A user copies the names
     they want into "tasks", exactly as they write "coordinates" after seeing
     what a project needs.

     It is explicit rather than automatic because it provisions and runs Gradle
     twice, and a `daukle tasks` that did that would make listing tasks the
     slowest command in the tool. ]]
daukle.task{
  name = "gradle:discover",
  run = function(context)
    local config = validation.config_of(context)
    local marker = discovery.MARKER
    --[[ The baseline is computed, never stored: Gradle's own task set differs
         between majors, and a stored one is a number that gets incremented,
         which is this project's most repeated failure. It is also THIS project
         with its apply lines removed rather than a bare one somewhere else, so
         the difference is what the plugins added and not what two projects
         happen to differ by. The second run reuses the daemon the first
         started. ]]
    local baseline = task_names_of(context, config, { bare = true, discover = marker })
    local full = task_names_of(context, config, { discover = marker })
    local contributed = discovery.contributed(full, baseline)

    --[[ Written before the names are mapped, because a name this toolchain
         cannot spell is exactly what the report exists to show. ]]
    daukle.write{ path = REPORT_FILE, text = discovery.report(contributed) }
    --[[ Leave the ordinary build file behind rather than the discovery one, so
         the next task does not run against a file carrying a listing task. ]]
    writer.write_build_file(context, config)
  end,
}

--[[ One daukle task per name the project asked for, read from the manifest by
     the name daukle was started from.

     The names come from daukle.toml and NOT from a file gradle:discover wrote,
     and that reversal is this design's correction to its own spec. A generated
     file read at chunk time cannot be read conditionally, so the project that
     declared it would fail EVERY command until the first discovery, including
     the discovery itself. Reading the manifest also leaves the project with one
     committed file instead of two, which is the file-location rule's third
     clause: if we can do without the file, we should. ]]
local function declared_tasks()
  local gradle = validation.MANIFEST ~= nil and validation.MANIFEST.toolchains ~= nil
                 and validation.MANIFEST.toolchains.gradle or nil
  return discovery.mapped(gradle ~= nil and gradle.tasks or nil)
end

for _, entry in ipairs(declared_tasks()) do
  --[[ Both spellings, because the mapping is lossy: core takes lowercase names
       only, so publishGithub and publishgithub both become publish-github and
       the reverse cannot be computed. ]]
  daukle.task{
    name = "gradle:" .. entry.daukle,
    run = function(context)
      local config = validation.config_of(context)
      writer.write_build_file(context, config)
      run_gradle(context, config, { entry.gradle })
    end,
  }
end
