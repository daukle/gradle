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
  --[[ 4, which daukle 0.12.0 is the first to provide, for the `files` a
       migration carrying build logic returns: an older daukle refuses this
       plugin by name, with its own version, instead of dropping the files and
       proving a build whose logic file is missing. ]]
  api = 4,
  uses = { "provision", "artifact", "exec", "write", "read", "parse", "list", "json_parse",
           "pin", "fetch", "cache" },
  exports = { "lib/distributions", "lib/build_file", "lib/junit", "lib/discovery", "lib/modules", "lib/migrate_logic",
              "lib/translation" },
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
      url = "https://github.com/daukle/java/releases/download/1.5.0/plugin.lua",
      sha256 = "94cecf60ad502541ce8fd1e087e335bf5eff65c67b651b94e21a9979e62b9b88",
    },
    maven = {
      url = "https://github.com/daukle/maven/releases/download/1.5.1/plugin.lua",
      sha256 = "39dba98f6a5b9d009bd296d823e2d6b2836edcd9d5486e2c4561ffb5832a9377",
    },
  },
}

local build_file = daukle.require("lib/build_file")
local discovery = daukle.require("lib/discovery")
local source_sets = daukle.require("lib/source_sets")
local validation = daukle.require("lib/validation")
local writer = daukle.require("lib/writer")
local launcher = daukle.require("lib/launcher")
local composite = daukle.require("lib/composite")
local migrator = daukle.require("lib/migrator")
local tool_defaults = daukle.require("lib/tool_defaults")
local configurations = daukle.require("lib/configurations")
local module_graph = daukle.require("lib/modules")
local carried = daukle.require("lib/carried")
local migrate_carry = daukle.require("lib/migrate_carry")
local resolve = daukle.require("maven:lib/resolve")
local output = daukle.require("maven:lib/output")
local pom = daukle.require("maven:lib/pom")

local REPORT_FILE = carried.DISCOVERY_REPORT

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
    return writer.generated_files(context, config)
  end,
}

daukle.migrator{ tool = "gradle", toolchain = "gradle", run = migrator.run, build = migrator.build }

local function run_gradle(context, config, arguments, options)
  local argv = {
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
  if carried.build_carries(config) then
    argv[#argv + 1] = "--project-cache-dir"
    argv[#argv + 1] = ".gradle"
  end
  for index = 1, #arguments do argv[#argv + 1] = arguments[index] end
  return launcher.run(context, validation.gradle_version_of(context), validation.jdk_version_of(config),
                      argv, options)
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
  name = "gradle:sources-jar",
  run = function(context)
    local config = validation.config_of(context)
    if config.sourcesJar ~= true then
      error('"gradle:sources-jar" needs "sourcesJar = true" in [toolchains.gradle], which is'
            .. ' what gives Gradle a sourcesJar task to run', 0)
    end
    writer.write_build_file(context, config)
    run_gradle(context, config, { "sourcesJar" })
  end,
}

local JARS_SCRIPT = carried.JARS_SCRIPT
local JARS_TASK = "daukleJars"

--- @implNote an init script rather than a line of the build file, so the
--- build file every other task renders stays the same.
local JARS_SCRIPT_TEXT = "gradle.allprojects { project ->\n"
  .. "  project.tasks.register('" .. JARS_TASK .. "') {\n"
  .. "    dependsOn(project.tasks.withType(org.gradle.api.tasks.bundling.Jar))\n"
  .. "  }\n"
  .. "}\n"

--- Whether a migration left the proof a report of its carried tasks.
---
--- @implNote read and listed from the project, where a write lands in the
--- derived directory; the read raises for a missing file, so it is listed first.
local function pending_carried_report(context)
  local directory = carried.derived_of(context.toolchain.name)
  for _, entry in ipairs(daukle.list(directory) or {}) do
    if entry.kind == "file" and entry.name == migrate_carry.REPORT_SCRIPT then
      return daukle.read(directory .. "/" .. migrate_carry.REPORT_SCRIPT) ~= ""
    end
  end
  return false
end

--- Every jar the manifest makes: every task of the `Jar` type in each
--- project, the sources jar and a plugin's own jar tasks included, and each
--- included build's, which `gradle:jar` alone leaves to whoever depends on
--- them. It is the proof a migration runs.
daukle.task{
  name = "gradle:jars",
  run = function(context)
    local config = validation.config_of(context)
    writer.write_build_file(context, config)
    daukle.write{ path = JARS_SCRIPT, text = JARS_SCRIPT_TEXT }
    local arguments = { "--init-script", JARS_SCRIPT, JARS_TASK }
    local reports_carried = pending_carried_report(context)
    if reports_carried then
      table.insert(arguments, 1, migrate_carry.REPORT_SCRIPT)
      table.insert(arguments, 1, "--init-script")
    end
    for _, build in ipairs(validation.composite_of(context, config).builds) do
      arguments[#arguments + 1] = ":" .. composite.build_name_of(build.name) .. ":" .. JARS_TASK
    end
    run_gradle(context, config, arguments)
    if reports_carried then daukle.write{ path = migrate_carry.REPORT_SCRIPT, text = "" } end
  end,
}

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

local TOOLS_FILE = "tools.lua"
local TOOLS_DIRECTORY = "daukle/gradle"
local TOOLS_PATH = TOOLS_DIRECTORY .. "/" .. TOOLS_FILE
--- @implNote passed to `daukle/maven`'s resolver, whose module core runs with no verbs of its own.
local RESOLVER_VERBS = { cache = daukle.cache, fetch = daukle.fetch, pin = daukle.pin }
local TOOLS_HEADER = "-- Generated by gradle:resolve-tools. Do not edit: daukle.toml is yours,"
                     .. " this is not."

--- @implNote `daukle.list` lists a directory and answers nil for a file, so the directory is listed.
local function tools_file_exists()
  for _, entry in ipairs(daukle.list(TOOLS_DIRECTORY) or {}) do
    if entry.kind == "file" and entry.name == TOOLS_FILE then return true end
  end
  return false
end

--- Refused before Gradle starts, by rewriting the committed file with what it already holds.
---
--- @implNote a plugin cannot ask whether the run resolves and has no pcall, so the committed
--- write core allows only under `--resolve` is the question, and core's refusal names the flag.
local function refuse_outside_a_resolve_run()
  local current = tools_file_exists() and daukle.read(TOOLS_PATH)
                  or output.render({}, TOOLS_HEADER, TOOLS_PATH)
  daukle.write{ path = TOOLS_FILE, text = current, committed = true }
  return current
end

--- Configurations left to the user: set in `daukle.toml`, or pinned by hand in `daukle.lua`.
local function user_filled_configurations(config, generated)
  local names = tool_defaults.user_filled(validation.MANIFEST, "gradle")
  for name in pairs(tool_defaults.hand_pinned(config, generated)) do names[name] = true end
  return names
end

--- What every project's configurations would download by default, as Gradle prints it.
---
--- @implNote `--no-daemon`, because a resolve run is rare and should leave no daemon behind.
local function reported_tool_defaults(context, config)
  writer.write_build_file(context, config, { without_named = true })
  daukle.write{ path = tool_defaults.SCRIPT, text = tool_defaults.SCRIPT_TEXT }
  local result = run_gradle(context, config,
                            { "--no-daemon", "--init-script", tool_defaults.SCRIPT, "help", "--quiet" },
                            { capture = true, check = false })
  if result.code ~= 0 then
    error("Gradle failed while reporting the tools its plugins download: "
          .. launcher.stderr_tail(result), 0)
  end
  if result.truncated then
    error("Gradle's report of the tools its plugins download was truncated, so some would go"
          .. " unpinned", 0)
  end
  return tool_defaults.reported(result.stdout)
end

local function declared_module_names(context)
  local names = {}
  for _, module in ipairs(module_graph.declared(context)) do names[#names + 1] = module.name end
  return names
end

--- @implNote a fresh session per resolution, because a session accumulates what it skipped and
--- the refusal must name the configuration each skipped dependency belongs to.
--- @implNote every POM is read through `daukle.cache`, so the second resolution makes no request.
local function skipped_dependencies_of(resolution)
  local session = resolve.sessions_of(RESOLVER_VERBS)(resolution.repository)
  local _, _, _, skipped = resolve.closures(resolution, session)
  return skipped
end

--- Pins the closure of every tool a configuration downloads by default into the committed
--- `daukle/gradle/tools.lua`, with `daukle/maven`'s own resolver.
---
--- @implNote the render Gradle reads leaves every `configurations.<name>` pin out, this file's
--- included, so a second run reads the same defaults and a changed `toolVersion` is seen.
daukle.task{
  name = "gradle:resolve-tools",
  run = function(context)
    local config = validation.config_of(context)
    local generated = refuse_outside_a_resolve_run()
    local reported, unplaceable = reported_tool_defaults(context, config)
    local skipped = user_filled_configurations(config, generated)
    tool_defaults.refuse_unplaceable(reported, unplaceable, skipped, configurations.name_problem)
    local resolutions = tool_defaults.resolutions(
      reported, skipped,
      { target = "gradle", repository = pom.CENTRAL, strategy = "highest",
        modules = declared_module_names(context), path_of = build_file.gradle_path })
    tool_defaults.refuse_skipped(resolutions, skipped_dependencies_of)
    daukle.write{ path = TOOLS_FILE, committed = true,
                  text = output.render(resolve.pinned_groups(resolutions, RESOLVER_VERBS),
                                       TOOLS_HEADER, TOOLS_PATH) }
    writer.write_build_file(context, config, { without_named = true })
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
local function manifest_gradle()
  return validation.MANIFEST ~= nil and validation.MANIFEST.toolchains ~= nil
         and validation.MANIFEST.toolchains.gradle or nil
end

local function declared_tasks()
  local gradle = manifest_gradle()
  return discovery.mapped(gradle ~= nil and gradle.tasks or nil)
end

--[[ Both spellings, because the mapping is lossy: core takes lowercase names
     only, so publishGithub and publishgithub both become publish-github and
     the reverse cannot be computed. ]]
local function gradle_runner(gradle_name)
  return function(context)
    local config = validation.config_of(context)
    writer.write_build_file(context, config)
    run_gradle(context, config, { gradle_name })
  end
end

local registered = {}
for _, entry in ipairs(declared_tasks()) do
  registered[entry.daukle] = true
  daukle.task{ name = "gradle:" .. entry.daukle, run = gradle_runner(entry.gradle) }
end

--[[ A colliding test set is left for `validated` to refuse by name: registering
     a second task of one name here is fatal on every command, `sync` included. ]]
for _, name in ipairs(source_sets.declared_test_names(manifest_gradle())) do
  local task = discovery.task_name(name)
  if not discovery.STATIC[task] and not registered[task] then
    registered[task] = true
    daukle.task{ name = "gradle:" .. task, run = gradle_runner(name) }
  end
end
