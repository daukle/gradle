--- A whole dumped build translated: its projects into one project or into
--- core `[modules]` plus `modules.<name>` blocks, its settings plugins, and its
--- included builds through lib/translate_included_builds.
---
--- @implNote a module is named by its directory, and Gradle's path for it is
--- derived from that name, so a project whose path is not its directory's
--- blocks: its jar and every `project(...)` edge would change name.
local translate_build = {}

local translate_model = daukle.require("lib/translate_model")
local translate_included_builds = daukle.require("lib/translate_included_builds")
local module_graph = daukle.require("lib/modules")
local migrate_surface = daukle.require("lib/migrate_surface")
local migrate_paths = daukle.require("lib/migrate_paths")
local tables = daukle.require("lib/tables")

local append = tables.append
local split_keys = tables.split_keys
local within = migrate_paths.within
local ROOT_PATH = ":"

--- The keys that hold one value for every module, so the modules must agree on it:
--- one JDK runs the whole build.
local PROJECT_WIDE_KEYS = { "jdk" }

--- Module keys a project-wide value composes with (D-168), hoisted when every module shares it.
local WHOLE_VALUE_KEYS = { "release", "sourcesJar" }

local function blocker(construct, where, why)
  return migrate_surface.blocker(construct, where, why, migrate_surface.UNCOVERED_ROW)
end

local deep_equal = tables.deep_equal

local function project_where(options, project)
  return within(options.dir, project.buildFile or options.settings)
end

local function project_options(model, options, context, where, extra)
  local out = { model = model, dir = options.dir, where = where, includedPluginIds = context.ids,
                includedPluginBuilds = context.plugin_builds, extensionDefaults = options.extensionDefaults }
  for key, value in pairs(extra or {}) do out[key] = value end
  return out
end

local function translate_single(model, options, context, blockers)
  local root = model.projects[1]
  local where = project_where(options, root)
  local translation = translate_model.project(root, project_options(model, options, context, where))
  append(blockers, translation.blockers)
  translation.config.requiresBuilds = translate_included_builds.required(translation, context.by_identity, where,
                                                                         blockers)
  return { config = translation.config, name = translation.name, version = translation.version,
           projects = { { project = root, where = where, unpinned = translation.unpinned,
                           blocked_edges = translation.blocked_edges } } }
end

local function ancestors_buildscript(project, by_path)
  local rows = {}
  local parent = by_path[project.parent or ""]
  while parent ~= nil do
    append(rows, (parent.buildscript or {}).resolved)
    parent = by_path[parent.parent or ""]
  end
  return rows
end

local function is_java(project)
  local extension = (project.extensions or {}).sourceSets
  return extension ~= nil
end

local function is_parent_of_a_module(project, modules)
  local prefix = project.dir .. "/"
  for _, name in ipairs(modules) do
    if string.sub(name, 1, #prefix) == prefix then return true end
  end
  return false
end

--- The subprojects that become modules, sorted, and the blockers for those
--- that cannot, whose paths go into `refused`.
local function module_projects(model, options, blockers, refused)
  local modules, names = {}, {}
  for index = 2, #model.projects do
    local project = model.projects[index]
    if is_java(project) then
      local problem = translate_included_builds.directory_problem(project.dir, project.path)
      if problem ~= nil then
        refused[project.path] = true
        blockers[#blockers + 1] = blocker(project.path, project_where(options, project), problem)
      else
        modules[project.dir] = project
        names[#names + 1] = project.dir
      end
    end
  end
  table.sort(names)
  return modules, names
end

local function union_by_url(target, entries, seen)
  for _, entry in ipairs(entries or {}) do
    if not seen[entry.url] then
      seen[entry.url] = true
      target[#target + 1] = entry
    end
  end
end

local function module_requires(translation, context, where, blockers)
  local requires = {}
  for _, path in ipairs(translation.requires) do
    local name = context.module_of_path[path]
    if name == nil then
      local reason = context.refused[path] and "it is blocked above" or "it applies no Java plugin"
      blockers[#blockers + 1] = blocker(path, where, "is a project the classpaths hold that becomes no module: "
                                        .. reason)
    else
      requires[#requires + 1] = name
    end
  end
  return requires
end

--- The module's `projectDependencies` block, its project paths as module
--- names, or nil when it declares none (spec D-211).
local function module_project_dependencies(translation, context, where, blockers)
  local block = {}
  for key, edges in pairs(translation.projectDependencies or {}) do
    local entries = {}
    for _, edge in ipairs(edges) do
      local name = context.module_of_path[edge.project]
      if name == nil then
        blockers[#blockers + 1] = blocker(edge.project, where, "is a project dependency on a project that becomes"
                                          .. " no module")
      elseif edge.configuration ~= nil then
        entries[#entries + 1] = { module = name, configuration = edge.configuration }
      else
        entries[#entries + 1] = name
      end
    end
    if #entries > 0 then block[key] = entries end
  end
  if next(block) == nil then return nil end
  return block
end

--- Blocks a project-wide key two modules disagree about, and returns the agreed values.
local function project_wide(module_results, blockers)
  local agreed = {}
  local first = module_results[1]
  for _, key in ipairs(PROJECT_WIDE_KEYS) do
    agreed[key] = first.rest[key]
    for index = 2, #module_results do
      local other = module_results[index]
      if not deep_equal(first.rest[key], other.rest[key]) then
        blockers[#blockers + 1] = blocker(key, other.where, "differs between the modules " .. first.name .. " and "
                                          .. other.name .. ", and it is a key every module shares")
      end
    end
  end
  return agreed
end

local function every_block_agrees(module_results, value_of)
  local first = value_of(module_results[1].block)
  for index = 2, #module_results do
    if not deep_equal(first, value_of(module_results[index].block)) then return false end
  end
  return true
end

local function hoist_whole_values(module_results, config)
  for _, key in ipairs(WHOLE_VALUE_KEYS) do
    if every_block_agrees(module_results, function(block) return block[key] end) then
      config[key] = module_results[1].block[key]
      for _, result in ipairs(module_results) do result.block[key] = nil end
    end
  end
end

local function same_plugin(left, right)
  return left ~= nil and right ~= nil and left.id == right.id and left.version == right.version
end

local function plugins_of(result)
  return result.block.plugins or {}
end

local function shared_prefix_length(module_results)
  local first = plugins_of(module_results[1])
  for index = 1, #first do
    for _, result in ipairs(module_results) do
      if not same_plugin(first[index], plugins_of(result)[index]) then return index - 1 end
    end
  end
  return #first
end

local function slice(list, from, to)
  local out = {}
  for index = from, to do out[#out + 1] = list[index] end
  return out
end

--- @implNote a common PREFIX rather than a set: the project-wide plugins render before a module's
--- own, so only a prefix keeps each module's order of application among its core ids and among its
--- pinned ones (the render applies core ids before pinned ones either way).
local function hoist_plugin_prefix(module_results, config)
  local shared = shared_prefix_length(module_results)
  if shared == 0 then return end
  config.plugins = slice(plugins_of(module_results[1]), 1, shared)
  for _, result in ipairs(module_results) do
    local own = slice(plugins_of(result), shared + 1, #plugins_of(result))
    result.block.plugins = #own > 0 and own or nil
  end
end

local function hoist_shared_extensions(module_results, config)
  for name in pairs(module_results[1].block.configure or {}) do
    if every_block_agrees(module_results, function(block) return (block.configure or {})[name] end) then
      config.configure = config.configure or {}
      config.configure[name] = module_results[1].block.configure[name]
      for _, result in ipairs(module_results) do result.block.configure[name] = nil end
    end
  end
  for _, result in ipairs(module_results) do
    if result.block.configure ~= nil and next(result.block.configure) == nil then result.block.configure = nil end
  end
end

--- Moves into `config` what every module's block shares of the keys a module value composes
--- with, leaving each block only its own (D-168).
local function hoist_shared(module_results, config)
  hoist_whole_values(module_results, config)
  hoist_plugin_prefix(module_results, config)
  hoist_shared_extensions(module_results, config)
end

local function shared_version(module_results, blockers)
  local first = module_results[1]
  for index = 2, #module_results do
    local other = module_results[index]
    if other.version ~= first.version then
      blockers[#blockers + 1] = blocker("version", other.where, "differs between the modules " .. first.name
                                        .. " and " .. other.name .. ", and a daukle project has one version")
    end
  end
  return first.version
end

local function translate_module(model, project, name, options, context, blockers)
  local where = project_where(options, project)
  local translation = translate_model.project(project, project_options(model, options, context, where, {
    name = name, inheritedBuildscript = ancestors_buildscript(project, context.by_path) }))
  append(blockers, translation.blockers)
  local block, rest = split_keys(translation.config, module_graph.MODULE_KEYS)
  block.requiresBuilds = translate_included_builds.required(translation, context.by_identity, where, blockers)
  block.projectDependencies = module_project_dependencies(translation, context, where, blockers)
  return { name = name, project = project, where = where, block = block, rest = rest, version = translation.version,
           requires = module_requires(translation, context, where, blockers),
           unpinned = translation.unpinned, blocked_edges = translation.blocked_edges }
end

--- A parent project's directory, which is the name its `parents` block takes.
local function parent_name(project)
  return (string.gsub(string.sub(project.path, 2), ":", "/"))
end

--- The `root` or `parents.<name>` block a parent's translation gives, or nil.
local function parent_block(config)
  local block = { plugins = config.plugins, configure = config.configure }
  if next(block) == nil then return nil end
  return block
end

--- @return the parents' comparison entries, the root's name, and their blocks by name ("" for the root)
local function translate_parents(model, options, context, names, blockers, plugin_classpath, seen)
  local parents = {}
  local blocks = {}
  local root_name = nil
  for index, project in ipairs(model.projects) do
    if index == 1 or not is_java(project) then
      local where = project_where(options, project)
      if index > 1 and not is_parent_of_a_module(project, names) then
        blockers[#blockers + 1] = blocker(project.path, where, "applies no Java plugin and holds no module, so"
                                          .. " nothing in daukle/gradle's keys can be it")
      else
        local translation = translate_model.parent(project, project_options(model, options, context, where))
        append(blockers, translation.blockers)
        union_by_url(plugin_classpath, translation.config.pluginClasspath, seen)
        if index == 1 then root_name = translation.name end
        blocks[index == 1 and "" or parent_name(project)] = parent_block(translation.config)
        parents[#parents + 1] = { project = project, where = where, unpinned = translation.unpinned }
      end
    end
  end
  return parents, root_name, blocks
end

local function translate_modules(model, options, context, blockers)
  context.refused = {}
  local modules, names = module_projects(model, options, blockers, context.refused)
  context.module_of_path = {}
  for _, name in ipairs(names) do context.module_of_path[modules[name].path] = name end
  local plugin_classpath, seen = {}, {}
  local projects, root_name, parent_blocks = translate_parents(model, options, context, names, blockers,
                                                               plugin_classpath, seen)
  local results, declared, blocks = {}, {}, {}
  for _, name in ipairs(names) do
    local result = translate_module(model, modules[name], name, options, context, blockers)
    union_by_url(plugin_classpath, result.rest.pluginClasspath, seen)
    results[#results + 1] = result
    projects[#projects + 1] = { project = result.project, where = result.where, module = name,
                                unpinned = result.unpinned, blocked_edges = result.blocked_edges }
    declared[#declared + 1] = { name = name, requires = result.requires }
  end
  if #results == 0 then
    blockers[#blockers + 1] = blocker(ROOT_PATH, project_where(options, model.projects[1]), "has subprojects and"
                                      .. " none of them applies a Java plugin, so there is no module to translate")
    return { config = {}, name = root_name, projects = projects, declared = {} }
  end
  local config = project_wide(results, blockers)
  hoist_shared(results, config)
  for _, result in ipairs(results) do
    if next(result.block) ~= nil then blocks[result.name] = result.block end
  end
  if #plugin_classpath > 0 then config.pluginClasspath = plugin_classpath end
  if next(blocks) ~= nil then config.modules = blocks end
  config.root = parent_blocks[""]
  parent_blocks[""] = nil
  if next(parent_blocks) ~= nil then config.parents = parent_blocks end
  return { config = config, name = root_name, version = shared_version(results, blockers), projects = projects,
           declared = declared }
end

local function core_modules(declared)
  if declared == nil or #declared == 0 then return nil end
  local modules = {}
  for _, entry in ipairs(declared) do
    modules[entry.name] = #entry.requires > 0 and { requires = entry.requires } or {}
  end
  return modules
end

local function by_path_of(model)
  local by_path = {}
  for _, project in ipairs(model.projects) do by_path[project.path] = project end
  return by_path
end

--- @param model           the root build's model
--- @param included_models the included builds' models, by the name `includedBuilds` gives them
--- @param options         { dir = <context.dir>, settings = <the settings file, relative to dir>,
---                          extensionDefaults? = what `extension_defaults.read` returned, or its SKIP }
--- @return { config = <the [toolchains.gradle] keys>, name, version, modules = <core's [modules]>,
---           declared = { { name, requires } }, projects = { { project, where, module? } },
---           builds = { { dir, gradle_name, identity, project, where } }, blockers }
function translate_build.build(model, included_models, options)
  local blockers = {}
  local included = translate_included_builds.read(model, included_models, options, blockers)
  local context = { ids = included.ids, plugin_builds = included.plugin_builds, by_identity = included.by_identity,
                    by_path = by_path_of(model) }
  local result
  if #model.projects == 1 then
    result = translate_single(model, options, context, blockers)
  else
    result = translate_modules(model, options, context, blockers)
  end
  local settings = translate_model.settings(project_options(model, options, context,
                                                            within(options.dir, options.settings)))
  append(blockers, settings.blockers)
  for key, value in pairs(settings.config) do result.config[key] = value end
  result.config.builds = translate_included_builds.config(included.records, result.config.jdk, blockers)
  result.modules = core_modules(result.declared)
  result.builds = included.records
  result.blockers = blockers
  return result
end

--- The config block a place names, a module's created when it has none yet.
---
--- @param place { build = <an included build's directory> } or { module = <name> } or { root = true }
function translate_build.block_at(config, place)
  if place.build ~= nil then return config.builds[place.build] end
  if place.module ~= nil then
    config.modules = config.modules or {}
    config.modules[place.module] = config.modules[place.module] or {}
    return config.modules[place.module]
  end
  return config
end

--- Sets the `verbatim` key of one project in a translated config.
---
--- @param place { build = <an included build's directory> } or { module = <name> } or { root = true }
--- @param dsl "groovy" or "kotlin", the member the text is set as
--- @return false for a project that is neither, which no key can name
function translate_build.set_verbatim(config, place, dsl, text)
  local value = { [dsl] = text }
  if place.build ~= nil then
    config.builds[place.build].verbatim = value
  elseif place.module ~= nil then
    config.modules = config.modules or {}
    config.modules[place.module] = config.modules[place.module] or {}
    config.modules[place.module].verbatim = value
  elseif place.root then
    config.verbatim = value
  else
    return false
  end
  return true
end

--- Sets a build's carried settings code: the main build's, or an included build's.
--- @param place { root = true } or { build = <the included build's directory> }
function translate_build.set_settings_verbatim(config, place, dsl, text)
  local value = { [dsl] = text }
  if place.build ~= nil then
    config.builds[place.build].settingsVerbatim = value
  else
    config.settingsVerbatim = value
  end
end

return translate_build
