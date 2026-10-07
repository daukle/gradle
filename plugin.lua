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
  exports = { "lib/distributions", "lib/build_file", "lib/junit", "lib/discovery" },
  --[[ Core scrubs every credential it knows from a child it starts unless the
       plugin declares it, so an undeclared GITHUB_TOKEN would reach Gradle as
       unset and a generated `System.getenv(...) ?: ''` would hand the build an
       empty string with nothing saying why. 56 of this tree's 77 build files
       apply a plugin that takes one, which is what makes this the credential
       worth passing. DAUKLE_TOKEN is deliberately not here: see
       REFUSED_ENV in lib/build_file.lua. D-32. ]]
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
local junit = daukle.require("lib/junit")
local discovery = daukle.require("lib/discovery")
local jdks = daukle.require("java:lib/jdks")

local DEFAULT_JDK = "17"
local BUILD_FILE = "build.gradle"
local SETTINGS_FILE = "settings.gradle"
local REPORT_FILE = "discovered.txt"

local DEFAULT_LAYOUT = {
  sourceRoot = "src/main/java",
  resourceRoot = "src/main/resources",
  testSourceRoot = "src/test/java",
  testResourceRoot = "src/test/resources",
}

local function config_of(context)
  return context.toolchain ~= nil and context.toolchain.config or context.config
end

local function string_key(config, key, fallback)
  local value = config[key]
  if value == nil then return fallback end
  if type(value) ~= "string" then
    error('"' .. key .. '" must be a string, not a ' .. type(value), 0)
  end
  return value
end

local function jdk_version_of(config)
  return string_key(config, "jdk", DEFAULT_JDK)
end

local function jdk_for(context, config)
  return jdks.for_host{ os = context.host.os, arch = context.host.arch,
                        version = jdk_version_of(config) }
end

local function checked_classpath(entries, key)
  if entries == nil then return {} end
  if type(entries) ~= "table" then
    error('"' .. key .. '" must be a list of pinned entries, not a ' .. type(entries), 0)
  end
  for index = 1, #entries do
    local entry = entries[index]
    if type(entry) ~= "table" or type(entry.url) ~= "string"
       or type(entry.sha256) ~= "string" then
      error('"' .. key .. '[' .. index .. ']" needs a url and a sha256: every dependency this'
            .. ' toolchain gives Gradle is pinned before Gradle sees it', 0)
    end
  end
  return entries
end

local function layout_of(config)
  return {
    main = {
      java = { string_key(config, "sourceRoot", DEFAULT_LAYOUT.sourceRoot) },
      resources = { string_key(config, "resourceRoot", DEFAULT_LAYOUT.resourceRoot) },
    },
    test = {
      java = { string_key(config, "testSourceRoot", DEFAULT_LAYOUT.testSourceRoot) },
      resources = { string_key(config, "testResourceRoot", DEFAULT_LAYOUT.testResourceRoot) },
    },
  }
end

local function project_name(context)
  local name = context.project or "project"
  return (name:match("([^/]+)$") or name)
end

local function checked_plugins(entries)
  if entries == nil then return {} end
  if type(entries) ~= "table" then
    error('"plugins" must be a list of entries, not a ' .. type(entries), 0)
  end
  for index = 1, #entries do
    local entry = entries[index]
    if type(entry) ~= "table" or type(entry.id) ~= "string" or type(entry.version) ~= "string" then
      error('"plugins[' .. index .. ']" needs an "id" and a "version": the id is what Gradle'
            .. " applies and the version is what the pinned jars are checked against", 0)
    end
  end
  return entries
end

--[[ The jar a plugin is applied from is pinned somewhere else entirely, by
     daukle/maven, so nothing links the version the project APPLIES to the
     version it ACQUIRED. Bumping one and not the other is silent: Gradle
     applies whatever jar it was handed. The version has to appear in some
     pinned entry, which the Maven layout puts in the url and which a
     hand-written pin can carry in "as". ]]
local function refuse_a_version_no_pin_carries(plugins, pins)
  for index = 1, #plugins do
    local version = plugins[index].version
    local pinned = false
    for pin = 1, #pins do
      local entry = pins[pin]
      if entry.url:find("/" .. version .. "/", 1, true) ~= nil
         or (type(entry.as) == "string" and entry.as:find(" " .. version, 1, true) ~= nil) then
        pinned = true
      end
    end
    if not pinned then
      error('"plugins[' .. index .. ']" applies ' .. plugins[index].id .. " " .. version
            .. ', and no entry in "pluginClasspath" names that version: resolve the plugin'
            .. " marker at that version, or correct the one here", 0)
    end
  end
end

--- Everything `generate` can check without starting a process or fetching.
local function validated(context, config)
  distributions.for_version(config.version)
  jdk_for(context, config)
  layout_of(config)
  checked_classpath(config.classpath, "classpath")
  checked_classpath(config.testClasspath, "testClasspath")
  string_key(config, "release", nil)
  string_key(config, "main", nil)

  local plugins = checked_plugins(config.plugins)
  local plugin_jars = checked_classpath(config.pluginClasspath, "pluginClasspath")
  if #plugins > 0 and #plugin_jars == 0 then
    error('"plugins" names ' .. #plugins .. " plugin(s) and \"pluginClasspath\" is empty: a"
          .. " plugin is applied from a jar daukle pinned, so resolve its marker into"
          .. ' "pluginClasspath" first', 0)
  end
  refuse_a_version_no_pin_carries(plugins, plugin_jars)
  --[[ Rendered and thrown away, so a tree this refuses is refused by `daukle
       check` rather than by the task that would have written it. Running the
       real renderer is what stops the refusal drifting from the writer. ]]
  build_file.configuration(config.configure)
end

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
    local config = config_of(context)
    validated(context, config)
    return { [SETTINGS_FILE] = build_file.settings(project_name(context)) }
  end,
}

local function paths_of(entries)
  local paths = {}
  for index = 1, #entries do
    local entry = entries[index]
    paths[index] = tostring(daukle.artifact{ url = entry.url, sha256 = entry.sha256,
                                             as = entry.as })
  end
  return paths
end

--[[ `options` is how a discovery run differs from an ordinary one: it may
     suppress the apply lines and the configure blocks, and it names the marker
     the generated listing task prints with. Everything else about the two files
     is identical on purpose, so the difference between their task lists is what
     the plugins contributed and nothing else. ]]
local function write_build_file(context, config, options)
  --[[ Again here and not only in generate: a task is reachable without a sync,
       so a check that only ran there would be a check a user can walk past. ]]
  validated(context, config)
  local bare = options ~= nil and options.bare or false
  --[[ Not `bare and nil or config.configure`: in Lua that is config.configure
       for both values of bare, because nil is false. ]]
  local configure = config.configure
  if bare then configure = nil end
  local compile = checked_classpath(config.classpath, "classpath")
  local test = checked_classpath(config.testClasspath, "testClasspath")
  --[[ The test side of the classpath is the compile side FOLLOWED BY the
       test-only entries, which is the testImplementation/implementation
       separation daukle/maven writes against. ]]
  local test_reachable = {}
  for index = 1, #compile do test_reachable[#test_reachable + 1] = compile[index] end
  for index = 1, #test do test_reachable[#test_reachable + 1] = test[index] end
  junit.refuse_a_missing_launcher(test_reachable)

  return daukle.write{
    path = BUILD_FILE,
    text = build_file.render(layout_of(config),
                             { compile = paths_of(compile), test = paths_of(test),
                               plugin = bare and {}
                                        or paths_of(checked_classpath(config.pluginClasspath,
                                                                      "pluginClasspath")) },
                             { release = string_key(config, "release", nil),
                               main = string_key(config, "main", nil),
                               plugins = bare and {} or checked_plugins(config.plugins),
                               configure = configure,
                               discover = options ~= nil and options.discover or nil }),
  }
end

--- @implNote the launcher jar rather than `bin/gradle`, because that is a POSIX
--- shell script and `bin/gradle.bat` a batch file, and neither is a program
--- daukle can start on every host. The jar is what both scripts eventually
--- exec. Starting it with the provisioned java is also what makes JAVA_HOME
--- unnecessary: Gradle reports the daemon JVM as "no JDK specified, using
--- current Java home", which is the one daukle provisioned.
local function run_gradle(context, config, arguments, options)
  local pick = distributions.for_version(config.version)
  local jdk = jdk_for(context, config)

  local gradle_root = daukle.provision{ url = pick.url, sha256 = pick.sha256,
                                        as = "gradle " .. pick.version }
  local jdk_root = daukle.provision{ url = jdk.url, sha256 = jdk.sha256,
                                     as = "temurin " .. jdk_version_of(config) }

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
      local config = config_of(context)
      write_build_file(context, config)
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
    run_gradle(context, config_of(context), { "--version" })
  end,
}

--- Every task name Gradle reports for one rendering of the build file.
local function task_names_of(context, config, options)
  write_build_file(context, config, options)
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
    local config = config_of(context)
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
    write_build_file(context, config)
  end,
}

--[[ One daukle task per name the project asked for, read from the manifest by
     the name daukle was started from. Gated on the manifest being DECLARATIVE:
     core accepts a project whose only manifest is daukle.lua by falling back to
     the overlay, and daukle.parse refuses to run one. There is no pcall in the
     sandbox, so an unguarded parse is fatal on every command rather than only
     on these tasks, which is what daukle/cmake@1.4.0 shipped.

     The names come from daukle.toml and NOT from a file gradle:discover wrote,
     and that reversal is this design's correction to its own spec. A generated
     file read at chunk time cannot be read conditionally, so the project that
     declared it would fail EVERY command until the first discovery, including
     the discovery itself. Reading the manifest also leaves the project with one
     committed file instead of two, which is the file-location rule's third
     clause: if we can do without the file, we should. ]]
local function declarative_manifest()
  if string.match(daukle.manifest, "%.toml$") == nil then return nil end
  return daukle.parse(daukle.read(daukle.manifest), daukle.manifest)
end

local function declared_tasks()
  local document = declarative_manifest()
  local gradle = document ~= nil and document.toolchains ~= nil
                 and document.toolchains.gradle or nil
  return discovery.mapped(gradle ~= nil and gradle.tasks or nil)
end

for _, entry in ipairs(declared_tasks()) do
  --[[ Both spellings, because the mapping is lossy: core takes lowercase names
       only, so publishGithub and publishgithub both become publish-github and
       the reverse cannot be computed. ]]
  daukle.task{
    name = "gradle:" .. entry.daukle,
    run = function(context)
      local config = config_of(context)
      write_build_file(context, config)
      run_gradle(context, config, { entry.gradle })
    end,
  }
end
