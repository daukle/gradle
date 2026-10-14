local build_file = daukle.require("lib/build_file")
local settings_file = daukle.require("lib/settings_file")
local junit = daukle.require("lib/junit")
local module_graph = daukle.require("lib/modules")
local configurations = daukle.require("lib/configurations")
local validation = daukle.require("lib/validation")

local BUILD_FILE = "build.gradle"

--- A copy of `base` carrying `extra` as well, so one table of project-wide
--- options can serve a root file and every module file without being spelled
--- again per caller.
local function extended(base, extra)
  local out = {}
  for key, value in pairs(base) do out[key] = value end
  for key, value in pairs(extra) do out[key] = value end
  return out
end

local function paths_of(entries)
  local paths = {}
  for index = 1, #entries do
    local entry = entries[index]
    paths[index] = tostring(daukle.artifact{ url = entry.url, sha256 = entry.sha256,
                                             as = entry.as })
  end
  return paths
end

--- Every entry a test run can load, in declaration order.
---
--- @implNote it spans the configurations that reach the test RUNTIME classpath,
--- because that is where a JUnit launcher has to be to be loaded. compileOnly
--- and testCompileOnly are excluded for that reason rather than by omission, so
--- a launcher declared in either is still refused.
local function test_reachable(entries)
  return configurations.test_reachable(function(key) return entries[key] end)
end

--- The cache paths per configuration, which is the shape the renderer takes.
local function jars_of(entries, plugin_jars)
  local jars = { plugin = plugin_jars }
  for index = 1, #configurations.all do
    local key = configurations.all[index].key
    jars[key] = paths_of(entries[key])
  end
  return jars
end

--- @implNote written before anything that can return early, the bare discovery
--- render included: settings.gradle applies this file whenever the manifest
--- declares settings plugins or settings configure blocks, so every run that
--- starts Gradle needs it.
local function write_settings_plugins(config)
  local declared = validation.settings_plugins_of(config)
  if declared == nil then return end
  daukle.write{
    path = settings_file.SCRIPT,
    text = settings_file.settings_plugins(paths_of(declared.entries), declared.plugins,
                                          declared.configure),
  }
end

--- @implNote per module, because a module carries its own testClasspath: a
--- project-wide check would pass while one module's test runtime held a
--- platform engine and no launcher, which is the declaration that passes on
--- Gradle 8 and dies on the next major.
local function refuse_a_module_missing_launcher(module)
  junit.refuse_a_missing_launcher(test_reachable(module.entries))
end

--- Every build file Gradle reads, written into the derived directory.
---
--- `options` is how a discovery run differs from an ordinary one: it may
--- suppress the apply lines and the configure blocks, and it names the marker
--- the generated listing task prints with. Everything else about the two files
--- is identical on purpose, so the difference between their task lists is what
--- the plugins contributed and nothing else.
---
--- @implNote `release`, `plugins` and `configure` are project-wide and are
--- rendered into EVERY module rather than into an `allprojects {}` block: the
--- renderer is the only writer, so the duplication costs a reader nothing and
--- there is no second configuration mechanism to learn.
--- @implNote the root file is written on every multi-project run, carrying only
--- its header when there is no plugin classpath. A task's write is not in
--- core's generate ledger and core prunes nothing, so a single-project build
--- file an earlier build left at the derived root would otherwise stay the root
--- project of this one, with its own source roots, its own jar and its own
--- daukleRun. An undeclared parent of a nested module gets a header-only file
--- for the same reason: it was a module once, and Gradle would read what that
--- run left in its directory.
local function write_build_file(context, config, options)
  --[[ Again here and not only in generate: a task is reachable without a sync,
       so a check that only ran there would be a check a user can walk past. ]]
  validation.validated(context, config)
  write_settings_plugins(config)
  local bare = options ~= nil and options.bare or false
  --[[ Not `bare and nil or config.configure`: in Lua that is config.configure
       for both values of bare, because nil is false. ]]
  local configure = config.configure
  if bare then configure = nil end
  local entries = validation.entries_of_configurations(config, "")
  junit.refuse_a_missing_launcher(test_reachable(entries))

  --[[ Built once and extended per file rather than spelled once per branch: a
       project-wide key added to one of two copies is a key half the projects
       get, and `plugins` was also revalidated once per module. ]]
  local plugin_jars = bare and {}
                      or paths_of(validation.checked_classpath(config.pluginClasspath,
                                                               "pluginClasspath"))
  local project_wide = { release = module_graph.string_key(config, "release", nil),
                         plugins = bare and {} or validation.checked_plugins(config.plugins),
                         configure = configure,
                         discover = options ~= nil and options.discover or nil }

  local declared = module_graph.declared(context)
  if #declared == 0 then
    return daukle.write{
      path = BUILD_FILE,
      text = build_file.render(validation.layout_of(config),
                               jars_of(entries, plugin_jars),
                               extended(project_wide,
                                        { main = module_graph.string_key(config, "main", nil) })),
    }
  end

  daukle.write{ path = BUILD_FILE, text = build_file.buildscript(plugin_jars) }

  local modules = validation.checked_modules(config, declared)
  for index = 1, #modules do
    local module = modules[index]
    refuse_a_module_missing_launcher(module)
    daukle.write{
      path = module.name .. "/" .. BUILD_FILE,
      text = build_file.module(module.name, module.layout,
                               jars_of(module.entries, {}),
                               extended(project_wide,
                                        { main = module.main,
                                          requires = module.requires })),
    }
  end

  local parents = module_graph.undeclared_parents(declared)
  for index = 1, #parents do
    daukle.write{ path = parents[index] .. "/" .. BUILD_FILE, text = build_file.empty_project() }
  end
end

return {
  write_build_file = write_build_file,
}
