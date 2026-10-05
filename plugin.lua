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
  uses = { "provision", "artifact", "exec", "write" },
  exports = { "lib/distributions", "lib/build_file", "lib/junit" },
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
local jdks = daukle.require("java:lib/jdks")

local DEFAULT_JDK = "17"
local BUILD_FILE = "build.gradle"
local SETTINGS_FILE = "settings.gradle"

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

--- Everything `generate` can check without starting a process or fetching.
local function validated(context, config)
  distributions.for_version(config.version)
  jdk_for(context, config)
  layout_of(config)
  checked_classpath(config.classpath, "classpath")
  checked_classpath(config.testClasspath, "testClasspath")
  string_key(config, "release", nil)
  string_key(config, "main", nil)
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

local function write_build_file(context, config)
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
                             { compile = paths_of(compile), test = paths_of(test) },
                             { release = string_key(config, "release", nil),
                               main = string_key(config, "main", nil) }),
  }
end

--- @implNote the launcher jar rather than `bin/gradle`, because that is a POSIX
--- shell script and `bin/gradle.bat` a batch file, and neither is a program
--- daukle can start on every host. The jar is what both scripts eventually
--- exec. Starting it with the provisioned java is also what makes JAVA_HOME
--- unnecessary: Gradle reports the daemon JVM as "no JDK specified, using
--- current Java home", which is the one daukle provisioned.
local function run_gradle(context, config, arguments)
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
  daukle.exec(java, argv)
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
