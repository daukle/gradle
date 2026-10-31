local distributions = daukle.require("lib/distributions")
local build_file = daukle.require("lib/build_file")
local module_graph = daukle.require("lib/modules")
local configurations = daukle.require("lib/configurations")
local builds = daukle.require("lib/builds")
local jdks = daukle.require("java:lib/jdks")
local source_sets = daukle.require("lib/source_sets")
local extensions = daukle.require("lib/extensions")
local carried = daukle.require("lib/carried")
local catalogs = daukle.require("lib/catalogs")
local verbatim = daukle.require("lib/verbatim")
local tables = daukle.require("lib/tables")
local declared_configurations = daukle.require("lib/declared_configurations")
local parents = daukle.require("lib/parents")
local project_dependencies = daukle.require("lib/project_dependencies")

local DEFAULT_JDK = "17"

--[[ Gated on the manifest being DECLARATIVE: core accepts a project whose only
     manifest is daukle.lua by falling back to the overlay, and daukle.parse
     refuses to run one. There is no pcall in the sandbox, so an unguarded parse
     is fatal on every command rather than only where the document is wanted,
     which is what daukle/cmake@1.4.0 shipped. ]]
local function declarative_manifest()
  if string.match(daukle.manifest, "%.toml$") == nil then return nil end
  return daukle.parse(daukle.read(daukle.manifest), daukle.manifest)
end

local MANIFEST = declarative_manifest()

--- Whether the manifest ITSELF declares modules, which is the one question a
--- core too old to publish its module list cannot be asked.
---
--- @implNote read from the parsed manifest rather than from a context, because
--- the context is exactly what such a core leaves out. A project whose manifest
--- is daukle.lua cannot be read at all, so this is false there and nothing is
--- refused, which is what every overlay project already gets.
local function manifest_declares_modules(document)
  local declared = document ~= nil and document.modules or nil
  return type(declared) == "table" and next(declared) ~= nil
end

local MANIFEST_DECLARES_MODULES = manifest_declares_modules(MANIFEST)

local TOOLCHAIN = "gradle"

local function instance_in_manifest(dir)
  local toolchains = MANIFEST ~= nil and MANIFEST.toolchains or nil
  if type(toolchains) ~= "table" then return nil end
  for name, block in pairs(toolchains) do
    if type(block) == "table" and (block.toolchain or name) == TOOLCHAIN and block.dir == dir then return name end
  end
  return nil
end

--- The toolchain instance a context belongs to, which names its `daukle/<instance>/`
--- and `build/daukle/<instance>/`.
---
--- @implNote a task's context names it and the migrator's names it; generate's
--- does not, so it is the manifest's gradle instance at the context's `dir`.
local function instance_of(context)
  if context.toolchain ~= nil and context.toolchain.name ~= nil then return context.toolchain.name end
  if context.instance ~= nil then return context.instance end
  return instance_in_manifest(carried.dir_of_root(context.root)) or TOOLCHAIN
end

local function config_of(context)
  return context.toolchain ~= nil and context.toolchain.config or context.config
end

local string_key = module_graph.string_key

--- @implNote core keeps a toolchain's `version` in the config a GENERATE callback
--- sees and drops it from a TASK's, exposing it as context.toolchain.version
--- instead. Reading only `config.version` therefore found a version at generate
--- time, refused an unpinned one correctly, and then provisioned the DEFAULT
--- Gradle in every task. `jdk` is unaffected: core reserves `version` and
--- `dependencies` and passes every other key through both callbacks.
local function gradle_version_of(context)
  return (context.toolchain ~= nil and context.toolchain.version)
         or config_of(context).version
end

local function jdk_version_of(config)
  return string_key(config, "jdk", DEFAULT_JDK)
end

local function jdk_for(context, config)
  return jdks.for_host{ os = context.host.os, arch = context.host.arch,
                        version = jdk_version_of(config) }
end

local function layout_of(config)
  return module_graph.layout_of(nil, config)
end

local checked_classpath = configurations.checked_entries
local entries_of_configurations = configurations.entries_of

local function project_name(context)
  local name = context.project or "project"
  return (name:match("([^/]+)$") or name)
end

local function checked_included_settings(value, label)
  local problem = verbatim.included_settings_problem_of(value, label)
  if problem ~= nil then error(problem, 0) end
  return verbatim.checked(value, label)
end

--- @implNote an included build takes only its own `configurations`, never the project-wide ones:
--- the plugin that adds a configuration is applied to the project, not inside an included build.
local function checked_builds(context, config)
  local declared = module_graph.declared(context)
  local read = builds.read(config, declared, project_name(context), MANIFEST)
  local release = string_key(config, "release", nil)
  local checked = {}
  for index = 1, #read do
    local build = read[index]
    local scope = "builds." .. build.name .. "."
    checked[index] = { name = build.name, gradle_name = build.gradle_name,
      plugin_build = #build.gradle_plugins > 0, gradle_plugins = build.gradle_plugins,
      layout = module_graph.layout_of(build.name, build.block, "builds"),
      release = string_key(build.block, "release", release, scope .. "release"),
      entries = entries_of_configurations(build.block, scope),
      named = configurations.named(build.block, scope),
      declared_configurations = declared_configurations.read(build.block, scope, {}),
      verbatim = verbatim.checked(build.block.verbatim, scope .. "verbatim"),
      settings_verbatim = checked_included_settings(build.block.settingsVerbatim, scope .. "settingsVerbatim"),
      catalogs = catalogs.checked(build.block.catalogs, scope .. "catalogs",
                                  carried.included_build_carries(build.block)) }
  end
  return checked, read
end

local function checked_catalogs(context, config)
  return catalogs.checked(config.catalogs, "catalogs", carried.build_carries(config))
end

local function is_pinned_plugin(entry)
  return type(entry) == "table" and type(entry.id) == "string" and type(entry.version) == "string"
end

local function is_included_plugin(entry, owners)
  return type(entry) == "table" and type(entry.id) == "string" and entry.version == nil
         and owners ~= nil and owners[entry.id] ~= nil
end

local function is_core_plugin(entry, owners)
  return type(entry) == "table" and type(entry.id) == "string" and entry.version == nil
         and not is_included_plugin(entry, owners)
end

--- @implNote only a project's `plugins`, its own or a module's, takes an id with no version and no owner: Gradle
--- resolves it from its own distribution and says so itself when it cannot, so daukle keeps no
--- list of ids. The settings list has no such form and keeps requiring a version.
local function takes_core_plugins(key)
  return key == "plugins" or key:sub(-#".plugins") == ".plugins"
end

local function is_acceptable_plugin(entry, key, owners)
  return is_pinned_plugin(entry) or is_included_plugin(entry, owners)
         or (takes_core_plugins(key) and is_core_plugin(entry, owners))
end

local function has_invalid_version(entry)
  return type(entry) == "table" and type(entry.id) == "string"
         and entry.version ~= nil and type(entry.version) ~= "string"
end

local function unacceptable_plugin_message(key, index, entry)
  if has_invalid_version(entry) then
    return '"' .. key .. '[' .. index .. '].version" must be a string, not a ' .. type(entry.version)
  end
  if takes_core_plugins(key) then
    return '"' .. key .. '[' .. index .. ']" needs an "id": the id is what Gradle applies, with a'
           .. ' "version" when a pinned jar carries it'
  end
  return '"' .. key .. '[' .. index .. ']" needs an "id" and a "version": the id is what Gradle'
         .. " applies and the version is what the pinned jars are checked against, or name a"
         .. ' plugin an included build declares in "gradlePlugins"'
end

--- Why `checked_plugins` would refuse this list, or nil.
local function plugins_problem(entries, key, owners)
  if entries == nil then return nil end
  if type(entries) ~= "table" then
    return '"' .. key .. '" must be a list of entries, not a ' .. type(entries)
  end
  for index = 1, #entries do
    if not is_acceptable_plugin(entries[index], key, owners) then
      return unacceptable_plugin_message(key, index, entries[index])
    end
  end
  return nil
end

--- @return the pinned entries, the ids an included build owns, and the ids Gradle itself decides
local function checked_plugins(entries, key, owners)
  key = key or "plugins"
  local problem = plugins_problem(entries, key, owners)
  if problem ~= nil then error(problem, 0) end
  local pinned, included, core = {}, {}, {}
  for _, entry in ipairs(entries or {}) do
    if is_pinned_plugin(entry) then
      pinned[#pinned + 1] = entry
    elseif is_included_plugin(entry, owners) then
      included[#included + 1] = entry.id
    else
      core[#core + 1] = entry.id
    end
  end
  return pinned, included, core
end

--[[ The jar a plugin is applied from is pinned somewhere else entirely, by
     daukle/maven, so nothing links the version the project APPLIES to the
     version it ACQUIRED. Bumping one and not the other is silent: Gradle
     applies whatever jar it was handed. The version has to appear in some
     pinned entry, which the Maven layout puts in the url and which a
     hand-written pin can carry in "as". ]]
local function unpinned_plugin_version(plugins, pins, plugins_key, classpath_key)
  for index = 1, #plugins do
    local version = plugins[index].version
    local pinned = version == nil
    for pin = 1, pinned and 0 or #pins do
      local entry = pins[pin]
      if entry.url:find("/" .. version .. "/", 1, true) ~= nil
         or (type(entry.as) == "string" and entry.as:find(" " .. version, 1, true) ~= nil) then
        pinned = true
      end
    end
    if not pinned then
      return '"' .. plugins_key .. '[' .. index .. ']" applies ' .. plugins[index].id .. " "
             .. version .. ', and no entry in "' .. classpath_key .. '" names that version:'
             .. ' run "daukle maven:resolve --resolve" with the marker at that version, which this'
             .. " check lets through (daukle 0.16.0 or newer). Or correct the version here"
    end
  end
  return nil
end

--- Why one plugin list cannot be applied from its classpath, or nil.
local function plugin_set_problem(plugins, jars, config, plugins_key, classpath_key)
  if #plugins > 0 and #jars == 0 then
    return '"' .. plugins_key .. '" names ' .. #plugins .. ' plugin(s) and "' .. classpath_key
           .. '" is empty: a plugin is applied from a jar daukle pinned. Run "daukle maven:resolve'
           .. ' --resolve" to pin it; a resolve run is the one command this check lets through'
           .. ' (daukle 0.16.0 or newer)'
  end
  return unpinned_plugin_version(config[plugins_key] or {}, jars, plugins_key, classpath_key)
end

local function read_plugin_set(config, plugins_key, classpath_key, owners)
  local plugins, included, core = checked_plugins(config[plugins_key], plugins_key, owners)
  local jars = checked_classpath(config[classpath_key], classpath_key)
  return plugins, jars, included, plugin_set_problem(plugins, jars, config, plugins_key, classpath_key), core
end

--- One plugin list and the classpath it is applied from, checked together:
--- the project's `plugins` and `pluginClasspath`, or the settings twins.
--- @return the pinned plugin entries, the pinned classpath entries, the included ids and the core ids
local function checked_plugin_set(config, plugins_key, classpath_key, owners)
  local plugins, jars, included, problem, core = read_plugin_set(config, plugins_key, classpath_key, owners)
  if problem ~= nil then error(problem, 0) end
  return plugins, jars, included, core
end

local function plugin_set_problem_of(config, plugins_key, classpath_key, owners)
  local problem = plugins_problem(config[plugins_key], plugins_key, owners)
                  or configurations.entries_problem(config[classpath_key], classpath_key)
  if problem ~= nil then return problem end
  local _, _, _, set_problem = read_plugin_set(config, plugins_key, classpath_key, owners)
  return set_problem
end

--- An id a module lists that the project-wide list already applies, or nil.
--- Refused rather than merged: the two entries can carry different versions.
local function repeated_plugin_problem(project_wide, own, key)
  local applied = {}
  for _, entry in ipairs(type(project_wide) == "table" and project_wide or {}) do
    if type(entry) == "table" and entry.id ~= nil then applied[entry.id] = true end
  end
  for index, entry in ipairs(type(own) == "table" and own or {}) do
    if type(entry) == "table" and applied[entry.id] then
      return '"' .. key .. '[' .. index .. ']" applies ' .. entry.id .. ', which "plugins" already'
             .. ' applies to every module: list it in one of the two places'
    end
  end
  return nil
end

--- A module's plugin list seen as a config of its own, labelled with where it
--- lives and checked against the project-wide classpath, which every module's
--- classloader inherits from the root build file (D-168).
local function module_plugin_view(config, block, scope)
  local key = scope .. "plugins"
  return { [key] = block.plugins, pluginClasspath = config.pluginClasspath }, key
end

local function checked_module_plugins(config, block, scope, owners)
  local view, key = module_plugin_view(config, block, scope)
  local pinned, _, included, core = checked_plugin_set(view, key, "pluginClasspath", owners)
  local repeated = repeated_plugin_problem(config.plugins, block.plugins, key)
  if repeated ~= nil then error(repeated, 0) end
  return { pinned = pinned, included = included, core = core }
end

--- Every module block that is a table, with the scope its keys are labelled by.
local function module_blocks(config)
  local found = {}
  for name, block in pairs(type(config.modules) == "table" and config.modules or {}) do
    if type(block) == "table" then found[#found + 1] = { name = name, block = block, scope = "modules." .. name .. "." } end
  end
  table.sort(found, function(left, right) return left.scope < right.scope end)
  return found
end

--- Every declared module with its own block read and shape-checked.
---
--- @implNote `validated` runs this and throws the result away, so a module's
--- classpath is refused by `daukle sync` and not only by the task that would
--- have written its file. One function rather than a second loop beside the
--- writer's: two loops over the same blocks would drift.
local function checked_modules(config, declared, read)
  local blocks = module_graph.blocks_of(config, declared)
  local project_wide = configurations.named(config, "")
  local project_options = module_graph.project_options(config)
  local owners = builds.owners(read)
  local names = {}
  for index = 1, #declared do names[index] = declared[index].name end
  local checked = {}
  for index = 1, #declared do
    local name = declared[index].name
    --[[ A module fault labelled "classpath" would name a key the manifest does
         not hold and that this plugin refuses project-wide. ]]
    local scope = "modules." .. name .. "."
    local block = blocks[name] or {}
    checked[index] = {
      name = name,
      requires = declared[index].requires,
      layout = module_graph.layout_of(name, block),
      main = string_key(block, "main", nil, scope .. "main"),
      entries = entries_of_configurations(block, scope),
      named = configurations.overridden(project_wide, configurations.named(block, scope)),
      required_builds = builds.required(block, scope .. "requiresBuilds", read),
      source_sets = source_sets.read(block, name),
      declared_configurations = declared_configurations.read(block, scope, names),
      project_dependencies = project_dependencies.read(block, scope, names, name),
      verbatim = verbatim.checked(block.verbatim, scope .. "verbatim"),
      release = string_key(block, "release", project_options.release, scope .. "release"),
      sources_jar = module_graph.boolean_key(block, "sourcesJar", project_options.sources_jar,
                                             scope .. "sourcesJar"),
      plugins = checked_module_plugins(config, block, scope, owners),
      configure = block.configure,
    }
    build_file.configuration(block.configure, nil, scope .. "configure")
  end
  module_graph.refuse_two_mains(checked)
  return checked
end

--- The root's and each implicit parent's block, checked: its plugins against
--- the project-wide classpath, which the root build file carries, and its
--- configure tree rendered once.
---
--- @implNote not checked against the project-wide `plugins`, which reach the
--- modules alone, so an id listed in both places applies once to each project.
--- @return { { name = <nil for the root>, plugins = { pinned, included, core }, configure } }
local function checked_parents(config, declared, owners)
  local checked = {}
  for _, found in ipairs(parents.blocks(config, declared)) do
    local key = found.label .. ".plugins"
    local view = { [key] = found.block.plugins, pluginClasspath = config.pluginClasspath }
    local pinned, _, included, core = checked_plugin_set(view, key, "pluginClasspath", owners)
    build_file.configuration(found.block.configure, nil, found.label .. ".configure")
    checked[#checked + 1] = { name = found.name, plugins = { pinned = pinned, included = included, core = core },
                              configure = found.block.configure }
  end
  return checked
end

local CONFIGURE_KEYS = { "settingsConfigure", "configure" }
local PLUGIN_SETS = { { "settingsPlugins", "settingsPluginClasspath" }, { "plugins", "pluginClasspath" } }

--- Whether a well-formed plugin list is refused only because its pins are
--- missing: an empty classpath, or a version no pinned entry carries.
local function lacks_only_its_pins(config, plugins_key, classpath_key, owners)
  if plugins_problem(config[plugins_key], plugins_key, owners) ~= nil then return false end
  if configurations.entries_problem(config[classpath_key], classpath_key) ~= nil then return false end
  local _, _, _, problem = read_plugin_set(config, plugins_key, classpath_key, owners)
  return problem ~= nil
end

--- The config `generate` renders: in a `--resolve` run, without a plugin list
--- whose pins are missing, so the resolve that writes them is not refused by
--- their absence (D-202). Every other run, and every task, still refuses.
---
--- @implNote nothing is printed, because generate has no output channel; the
--- first Gradle task or ordinary command after a resolve that left the pins
--- missing refuses with the usual message.
local function generated_config(context, config)
  if context.resolving ~= true then return config end
  local _, read = checked_builds(context, config)
  local owners = builds.owners(read)
  local relaxed
  for _, keys in ipairs(PLUGIN_SETS) do
    if lacks_only_its_pins(config, keys[1], keys[2], owners) then
      relaxed = relaxed or tables.shallow_copy(config)
      relaxed[keys[1]] = nil
    end
  end
  for _, module in ipairs(module_blocks(config)) do
    local view, key = module_plugin_view(config, module.block, module.scope)
    if lacks_only_its_pins(view, key, "pluginClasspath", owners) then
      relaxed = relaxed or tables.shallow_copy(config)
      if relaxed.modules == config.modules then relaxed.modules = tables.shallow_copy(config.modules) end
      relaxed.modules[module.name] = tables.shallow_copy(module.block)
      relaxed.modules[module.name].plugins = nil
    end
  end
  return relaxed or config
end

--- What `validated` would refuse in the plugin lists, their classpaths and the
--- configure trees, as reasons, for a caller that reports a refusal instead of
--- raising it.
local function plugin_set_problems(context, config)
  local _, read = checked_builds(context, config)
  local owners = builds.owners(read)
  local problems = {}
  for _, keys in ipairs(PLUGIN_SETS) do
    local problem = plugin_set_problem_of(config, keys[1], keys[2], owners)
    if problem ~= nil then problems[#problems + 1] = problem end
  end
  for _, key in ipairs(CONFIGURE_KEYS) do
    local problem = extensions.configuration_problem(config[key], key)
    if problem ~= nil then problems[#problems + 1] = problem end
  end
  for _, module in ipairs(module_blocks(config)) do
    local view, key = module_plugin_view(config, module.block, module.scope)
    local problem = plugin_set_problem_of(view, key, "pluginClasspath", owners)
                    or repeated_plugin_problem(config.plugins, module.block.plugins, key)
                    or extensions.configuration_problem(module.block.configure, module.scope .. "configure")
    if problem ~= nil then problems[#problems + 1] = problem end
  end
  return problems
end

local function composite_of(context, config)
  local checked, read = checked_builds(context, config)
  local owners = builds.owners(read)
  local plugin_builds, library_builds = {}, {}
  for index = 1, #checked do
    local list = checked[index].plugin_build and plugin_builds or library_builds
    list[#list + 1] = checked[index].name
  end
  local _, _, settings_ids = checked_plugin_set(config, "settingsPlugins",
                                                "settingsPluginClasspath", owners)
  local _, _, project_ids = checked_plugin_set(config, "plugins", "pluginClasspath", owners)
  return { builds = checked, read = read, owners = owners, plugin_builds = plugin_builds,
           library_builds = library_builds, settings_ids = settings_ids,
           project_ids = project_ids, required = builds.required(config, "requiresBuilds", read) }
end

--- @implNote core publishes `context.modules` as a table, empty when the
--- project declares none, so an ABSENT one is a core too old to publish the
--- list at all rather than a project without modules. Refused because nothing
--- downstream can tell the difference: the single-project file would be
--- rendered against source roots a module-shaped repository does not have, and
--- Gradle would report BUILD SUCCESSFUL having compiled nothing.
local function refuse_a_core_that_publishes_no_modules(context)
  if MANIFEST_DECLARES_MODULES and context.modules == nil then
    error('this project declares modules and the daukle running it is too old to publish the'
          .. ' module list, so every module in "[modules]" would be silently ignored: upgrade'
          .. ' daukle, or take the modules back out of the manifest', 0)
  end
end

--- Everything `generate` can check without starting a process or fetching.
---
--- @implNote the module checks live here rather than beside the writer so that
--- `daukle sync` refuses a bad graph. A project that declares modules reaches
--- generate and no task, so a check only the writer ran would be one a user
--- never meets until the first build.
local function validated(context, config)
  local retired = verbatim.retired_problem(config, instance_of(context))
  if retired ~= nil then error(retired, 0) end
  refuse_a_core_that_publishes_no_modules(context)
  distributions.for_version(gradle_version_of(context))
  jdk_for(context, config)
  layout_of(config)
  verbatim.checked(config.verbatim, "verbatim")
  verbatim.checked(config.settingsVerbatim, "settingsVerbatim")
  checked_catalogs(context, config)
  local declared = module_graph.declared(context)
  module_graph.refuse_a_module_key_project_wide(config, declared)
  local record = composite_of(context, config)
  source_sets.refuse_task_collisions(config,
                                     checked_modules(config, declared, record.read))
  checked_parents(config, declared, record.owners)
  entries_of_configurations(config, "")
  configurations.named(config, "")
  declared_configurations.read(config, "", {})
  module_graph.project_options(config)
  checked_plugin_set(config, "plugins", "pluginClasspath", record.owners)
  checked_plugin_set(config, "settingsPlugins", "settingsPluginClasspath", record.owners)
  --[[ Rendered and thrown away, so a tree this refuses is refused by `daukle
       check` rather than by the task that would have written it. Running the
       real renderer is what stops the refusal drifting from the writer. ]]
  build_file.configuration(config.configure)
  build_file.configuration(config.settingsConfigure, nil, "settingsConfigure")
end

--- The settings plugins and settings configure blocks the manifest declares,
--- or nil when it declares neither, which is also what decides whether
--- settings.gradle applies the script. A configure block needs no plugin:
--- `buildCache` and `toolchainManagement` are Gradle's own.
--- @return { plugins = table, entries = table, configure = table|nil }|nil
local function settings_plugins_of(config, owners)
  local plugins, entries = checked_plugin_set(config, "settingsPlugins", "settingsPluginClasspath",
                                              owners)
  local configure = config.settingsConfigure
  local configures = type(configure) == "table" and next(configure) ~= nil
  if #plugins == 0 and not configures then return nil end
  return { plugins = plugins, entries = entries, configure = configure }
end

return {
  MANIFEST = MANIFEST,
  config_of = config_of,
  generated_config = generated_config,
  gradle_version_of = gradle_version_of,
  jdk_version_of = jdk_version_of,
  jdk_for = jdk_for,
  layout_of = layout_of,
  checked_classpath = checked_classpath,
  entries_of_configurations = entries_of_configurations,
  checked_modules = checked_modules,
  checked_parents = checked_parents,
  instance_of = instance_of,
  checked_builds = checked_builds,
  checked_catalogs = checked_catalogs,
  composite_of = composite_of,
  project_name = project_name,
  checked_plugins = checked_plugins,
  plugin_set_problems = plugin_set_problems,
  settings_plugins_of = settings_plugins_of,
  validated = validated,
}
