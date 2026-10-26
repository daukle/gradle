local build_file = daukle.require("lib/build_file")
local settings_file = daukle.require("lib/settings_file")
local junit = daukle.require("lib/junit")
local module_graph = daukle.require("lib/modules")
local configurations = daukle.require("lib/configurations")
local validation = daukle.require("lib/validation")
local composite = daukle.require("lib/composite")
local source_sets = daukle.require("lib/source_sets")
local builds = daukle.require("lib/builds")

local BUILD_FILE = "build.gradle"
local SETTINGS_FILE = "settings.gradle"

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

local function with_paths(sets)
  for _, set in ipairs(sets) do
    set.paths = {}
    for key, entries in pairs(set.entries) do set.paths[key] = paths_of(entries) end
  end
  return sets
end

--- The cache paths per configuration, which is the shape the renderer takes.
local function jars_of(entries, plugin_jars, named)
  local jars = { plugin = plugin_jars, named = {} }
  for index, configuration in ipairs(named) do
    jars.named[index] = { name = configuration.name, paths = paths_of(configuration.entries) }
  end
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
local function write_settings_plugins(config, owners)
  local declared = validation.settings_plugins_of(config, owners)
  if declared == nil then return end
  daukle.write{
    path = settings_file.SCRIPT,
    text = settings_file.settings_plugins(paths_of(declared.entries), declared.plugins,
                                          declared.configure),
  }
end

--- @implNote written on every run, the bare discovery render included:
--- settings.gradle includes every declared build, so Gradle fails on any run
--- that starts without them.
local function write_included_builds(checked, named_of)
  for index = 1, #checked do
    local build = checked[index]
    local at = composite.path_of(build.name)
    junit.refuse_a_missing_launcher(test_reachable(build.entries))
    daukle.write{ path = at .. "/settings.gradle",
                  text = settings_file.included_settings(build.gradle_name) }
    daukle.write{ path = at .. "/" .. BUILD_FILE,
                  text = build_file.included(build.name, build.layout,
                                             jars_of(build.entries, {}, named_of(build.named)),
                                             { release = build.release, plugins = {},
                                               gradle_plugins = build.gradle_plugins,
                                               group = (not build.plugin_build)
                                                       and composite.GROUP or nil }) }
  end
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
--- the plugins contributed and nothing else. `without_named` leaves every
--- `configurations.<name>` pin out, so Gradle reports the default a pin would hide.
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
  local composite_record = validation.composite_of(context, config)
  local without_named = options ~= nil and options.without_named or false
  local bare = options ~= nil and options.bare or false
  local function named_of(named)
    if bare or without_named then return {} end
    return named
  end
  write_settings_plugins(config, composite_record.owners)
  write_included_builds(composite_record.builds, named_of)
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
  local project_options = module_graph.project_options(config)
  local pinned_plugins, core_plugins = {}, {}
  if not bare then
    local pinned, _, core = validation.checked_plugins(config.plugins, "plugins",
                                                       composite_record.owners)
    pinned_plugins, core_plugins = pinned, core
  end
  local project_wide = { release = project_options.release,
                         sources_jar = project_options.sources_jar,
                         version = context.version,
                         plugins = pinned_plugins,
                         core_plugins = core_plugins,
                         included_plugins = bare and {} or composite_record.project_ids,
                         configure = configure,
                         discover = options ~= nil and options.discover or nil }

  local declared = module_graph.declared(context)
  if #declared == 0 then
    return daukle.write{
      path = BUILD_FILE,
      text = build_file.render(validation.layout_of(config),
                               jars_of(entries, plugin_jars,
                                       named_of(configurations.named(config, ""))),
                               extended(project_wide,
                                        { main = project_options.main,
                                          required_builds = composite_record.required,
                                          source_sets = with_paths(source_sets.read(config, nil)) })),
    }
  end

  daukle.write{ path = BUILD_FILE, text = build_file.buildscript(plugin_jars) }

  local modules = validation.checked_modules(config, declared, composite_record.read)
  for index = 1, #modules do
    local module = modules[index]
    refuse_a_module_missing_launcher(module)
    daukle.write{
      path = module.name .. "/" .. BUILD_FILE,
      text = build_file.module(module.name, module.layout,
                               jars_of(module.entries, {}, named_of(module.named)),
                               extended(project_wide,
                                        { main = module.main,
                                          requires = module.requires,
                                          required_builds = module.required_builds,
                                          source_sets = with_paths(module.source_sets) })),
    }
  end

  local parents = module_graph.undeclared_parents(declared)
  for index = 1, #parents do
    daukle.write{ path = parents[index] .. "/" .. BUILD_FILE, text = build_file.empty_project() }
  end
end

--- The settings.gradle a validated config renders: generate returns it, and
--- the migrator writes it beside the build file it renders for its task-set
--- comparison, so both read one renderer.
local function settings_text(context, config)
  local record = validation.composite_of(context, config)
  local applies_settings_plugins = validation.settings_plugins_of(config, record.owners) ~= nil
  return settings_file.settings(validation.project_name(context), module_graph.declared(context),
                                applies_settings_plugins, record)
end

local function append_launcher_problem(problems, entries)
  local launcher = junit.missing_launcher(test_reachable(entries))
  if launcher ~= nil then problems[#problems + 1] = launcher end
end

--- The JUnit launcher and the one-main rule, per module and per included
--- build, since each carries its own test classpath.
local function per_project_problems(config, declared, problems)
  local blocks = config.modules or {}
  local mains = {}
  for _, module in ipairs(declared) do
    local block = blocks[module.name] or {}
    mains[#mains + 1] = { name = module.name, main = block.main }
    append_launcher_problem(problems, validation.entries_of_configurations(block, "modules." .. module.name .. "."))
  end
  local two_mains = module_graph.two_mains_problem(mains)
  if two_mains ~= nil then problems[#problems + 1] = two_mains end
  for name, block in pairs(config.builds or {}) do
    append_launcher_problem(problems, validation.entries_of_configurations(block, "builds." .. name .. "."))
  end
end

--- What `write_build_file` would refuse in this config, as reasons rather
--- than a raise, for the migrator, which reports a refusal as a blocker.
---
--- @implNote the refusals a translated config can meet: its module graph and
--- included builds, its plugin lists and their classpaths, its configure trees,
--- the JUnit launcher and two modules declaring `main`. Every other check in
--- `validated` is on a shape the translation never writes. A refused graph or
--- build list is returned alone, because every later check reads them.
local function generation_problems(context, config)
  local graph = module_graph.declared_problem(context)
  if graph ~= nil then return { graph } end
  local declared = module_graph.declared(context)
  local read = builds.read_problem(config, declared, validation.project_name(context))
  if read ~= nil then return { read } end
  local problems = validation.plugin_set_problems(context, config)
  append_launcher_problem(problems, validation.entries_of_configurations(config, ""))
  per_project_problems(config, declared, problems)
  return problems
end

return {
  SETTINGS_FILE = SETTINGS_FILE,
  generation_problems = generation_problems,
  settings_text = settings_text,
  write_build_file = write_build_file,
}
