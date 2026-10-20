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

--- The keys that hold one value for every module, so the modules must agree on it.
local PROJECT_WIDE_KEYS = { "jdk", "release", "sourcesJar", "plugins", "configure" }

local function blocker(construct, where, why)
  return migrate_surface.blocker(construct, where, why, migrate_surface.UNCOVERED_ROW)
end

local deep_equal = tables.deep_equal

local function project_where(options, project)
  return within(options.dir, project.buildFile or options.settings)
end

local function project_options(model, options, context, where, extra)
  local out = { model = model, dir = options.dir, where = where, includedPluginIds = context.ids,
                includedPluginBuilds = context.plugin_builds }
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
           projects = { { project = root, where = where, unpinned = translation.unpinned } } }
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

--- A plugin list as id -> version, because two modules applying the same
--- plugins in another order render the same lines in every module.
local function plugin_set(plugins)
  local set = {}
  for _, entry in ipairs(plugins or {}) do set[entry.id] = entry.version or true end
  return set
end

local function agrees(key, left, right)
  if key == "plugins" then return deep_equal(plugin_set(left), plugin_set(right)) end
  return deep_equal(left, right)
end

--- Blocks a project-wide key two modules disagree about, and returns the agreed values.
local function project_wide(module_results, blockers)
  local agreed = {}
  local first = module_results[1]
  for _, key in ipairs(PROJECT_WIDE_KEYS) do
    agreed[key] = first.rest[key]
    for index = 2, #module_results do
      local other = module_results[index]
      if not agrees(key, first.rest[key], other.rest[key]) then
        blockers[#blockers + 1] = blocker(key, other.where, "differs between the modules " .. first.name .. " and "
                                          .. other.name .. ", and it is a key every module shares")
      end
    end
  end
  return agreed
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
  return { name = name, project = project, where = where, block = block, rest = rest, version = translation.version,
           requires = module_requires(translation, context, where, blockers),
           unpinned = translation.unpinned }
end

local function translate_parents(model, options, context, names, blockers, plugin_classpath, seen)
  local parents = {}
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
        parents[#parents + 1] = { project = project, where = where, unpinned = translation.unpinned }
      end
    end
  end
  return parents, root_name
end

local function translate_modules(model, options, context, blockers)
  context.refused = {}
  local modules, names = module_projects(model, options, blockers, context.refused)
  context.module_of_path = {}
  for _, name in ipairs(names) do context.module_of_path[modules[name].path] = name end
  local plugin_classpath, seen = {}, {}
  local projects, root_name = translate_parents(model, options, context, names, blockers, plugin_classpath, seen)
  local results, declared, blocks = {}, {}, {}
  for _, name in ipairs(names) do
    local result = translate_module(model, modules[name], name, options, context, blockers)
    union_by_url(plugin_classpath, result.rest.pluginClasspath, seen)
    results[#results + 1] = result
    projects[#projects + 1] = { project = result.project, where = result.where, module = name,
                                unpinned = result.unpinned }
    declared[#declared + 1] = { name = name, requires = result.requires }
    if next(result.block) ~= nil then blocks[name] = result.block end
  end
  if #results == 0 then
    blockers[#blockers + 1] = blocker(ROOT_PATH, project_where(options, model.projects[1]), "has subprojects and"
                                      .. " none of them applies a Java plugin, so there is no module to translate")
    return { config = {}, name = root_name, projects = projects, declared = {} }
  end
  local config = project_wide(results, blockers)
  if #plugin_classpath > 0 then config.pluginClasspath = plugin_classpath end
  if next(blocks) ~= nil then config.modules = blocks end
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
--- @param options         { dir = <context.dir>, settings = <the settings file, relative to dir> }
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

return translate_build
