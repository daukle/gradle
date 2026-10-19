--- A whole dumped build translated: its projects into one project or into
--- core `[modules]` plus `modules.<name>` blocks, its included builds into
--- `builds.<dir>`, and its settings plugins.
---
--- @implNote a module is named by its directory, and Gradle's path for it is
--- derived from that name, so a project whose path is not its directory's
--- blocks: its jar and every `project(...)` edge would change name.
--- @implNote an included build's `group` and `version` are not carried: the
--- outer build reached it through a coordinate Gradle substituted, and the
--- generated build substitutes `daukle.included:<name>` instead, so neither
--- names anything the outer build's output holds.
local translate_build = {}

local translate_model = daukle.require("lib/translate_model")
local module_graph = daukle.require("lib/modules")
local builds = daukle.require("lib/builds")

local SURFACE = "GRADLE-SURFACE.md: "
local UNCOVERED_ROW = SURFACE .. "6. What this file does NOT yet cover, said plainly"
local GRADLE_PLUGINS = "gradlePlugins"
local ROOT_PATH = ":"
local CURRENT_BUILD = ":"

--- The keys that hold one value for every module, so the modules must agree on it.
local PROJECT_WIDE_KEYS = { "jdk", "release", "sourcesJar", "plugins", "configure" }

local function blocker(construct, where, why, surface)
  return { construct = construct, where = where, why = why, surface = surface or UNCOVERED_ROW }
end

local function append(target, source)
  for _, item in ipairs(source or {}) do target[#target + 1] = item end
end

local function within(dir, name)
  if dir == nil or dir == "." then return name end
  return dir .. "/" .. name
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
  return keys
end

local function deep_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return left == right end
  for key, value in pairs(left) do
    if not deep_equal(value, right[key]) then return false end
  end
  for key in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

local function is_inside(path)
  return path ~= nil and path ~= "." and path ~= ".." and string.sub(path, 1, 3) ~= "../"
         and string.sub(path, 1, 1) ~= "/" and string.match(path, "^%a:/") == nil
end

local function gradle_path(name)
  return ROOT_PATH .. (string.gsub(name, "/", ":"))
end

--- Why `dir` cannot name a module or an included build whose Gradle path is
--- `path` (nil for an included build), or nil.
local function name_problem(dir, path)
  if not is_inside(dir) then return "lies at " .. tostring(dir) .. ", outside the project's root" end
  local problem = module_graph.problem_of(dir)
  if problem ~= nil then return "lies in a directory whose name " .. problem end
  if path ~= nil and gradle_path(dir) ~= path then
    return "lies in " .. dir .. ", and with modules a project's Gradle path is its directory's, " .. gradle_path(dir)
  end
  return nil
end

local function project_where(options, project)
  return within(options.dir, project.buildFile or options.settings)
end

local function split_keys(config, keep)
  local kept, rest = {}, {}
  for key, value in pairs(config) do
    if keep[key] then kept[key] = value else rest[key] = value end
  end
  return kept, rest
end

local function gradle_plugins_of(project, where, blockers)
  local extension = (project.extensions or {}).gradlePlugin
  local value = extension ~= nil and extension.value or nil
  if type(value) ~= "table" or type(value.plugins) ~= "table" then return nil end
  local entries = {}
  for _, name in ipairs(sorted_keys(value.plugins)) do
    local plugin = value.plugins[name]
    local construct = "gradlePlugin.plugins." .. name
    if type(plugin.id) ~= "string" or type(plugin.implementationClass) ~= "string" then
      blockers[#blockers + 1] = blocker(construct, where, "names no id or implementation class the model could read")
    else
      if plugin.displayName ~= nil or plugin.description ~= nil then
        blockers[#blockers + 1] = blocker(construct, where, "sets a display name or a description, which a"
                                          .. " gradlePlugins entry cannot carry")
      end
      entries[#entries + 1] = { id = plugin.id, implementationClass = plugin.implementationClass }
    end
  end
  if #entries == 0 then return nil end
  return entries
end

local function has_third_party(plugins)
  for _, plugin in ipairs(plugins or {}) do
    if plugin.core ~= true then return true end
  end
  return false
end

--- One included build's root project as a `builds.<dir>` block, or nil and
--- the reason it cannot be one.
local function included_block(entry, model, options, blockers)
  if model == nil then
    return nil, "has no dumped model: the init script never reached its whenReady, so nothing it holds"
                .. " can be translated"
  end
  if #(model.projects or {}) ~= 1 then
    return nil, "has subprojects, and an included build block describes one project"
  end
  if #(model.includedBuilds or {}) > 0 then return nil, "includes builds of its own" end
  if has_third_party(model.settingsPlugins) then
    return nil, "applies settings plugins of its own, which a build block cannot say"
  end
  local project = model.projects[1]
  local where = within(options.dir, entry.dir .. "/" .. (project.buildFile or "."))
  local translation = translate_model.project(project, { model = model, dir = options.dir, where = where,
                                                         prefix = entry.dir .. "/", name = entry.dir })
  append(blockers, translation.blockers)
  local block, rest = split_keys(translation.config, builds.KEYS)
  for _, key in ipairs(sorted_keys(rest)) do
    if key ~= "jdk" then
      blockers[#blockers + 1] = blocker(key, where, "is set in an included build, and an included build block"
                                        .. " takes only source roots, release and dependency keys")
    end
  end
  if #translation.requiredBuilds > 0 then
    blockers[#blockers + 1] = blocker("requiresBuilds", where, "is an included build that depends on another"
                                      .. " included build, which a build block cannot say")
  end
  block[GRADLE_PLUGINS] = gradle_plugins_of(project, where, blockers)
  return { dir = entry.dir, gradle_name = (string.gsub(entry.dir, "/", "-")), project = project, where = where,
           block = block, jdk = rest.jdk, unpinned = translation.unpinned }
end

--- @return the build records, the set of plugin ids they declare, and old identity path -> record
local function included_builds(model, included_models, options, blockers)
  local records, ids, by_identity = {}, {}, {}
  local settings = within(options.dir, options.settings)
  for _, entry in ipairs(model.includedBuilds or {}) do
    local problem = name_problem(entry.dir, nil)
    local record = nil
    if problem == nil then record, problem = included_block(entry, included_models[entry.name], options, blockers) end
    if problem ~= nil then
      blockers[#blockers + 1] = blocker(tostring(entry.dir), settings, "is an included build that " .. problem)
    else
      record.identity = CURRENT_BUILD .. entry.name
      records[#records + 1] = record
      by_identity[record.identity] = record
      for _, plugin in ipairs(record.block[GRADLE_PLUGINS] or {}) do ids[plugin.id] = true end
    end
  end
  return records, ids, by_identity
end

local function plugin_builds_of(records)
  local identities = {}
  for _, record in ipairs(records) do
    if record.block[GRADLE_PLUGINS] ~= nil then identities[record.identity] = true end
  end
  return identities
end

--- The included builds a project's main classpaths hold, by directory; one
--- that supplies plugins blocks, because a plugin build is applied, not
--- depended on.
local function required_builds_of(translation, by_identity, where, blockers)
  local dirs = {}
  for _, identity in ipairs(translation.requiredBuilds) do
    local record = by_identity[identity]
    if record == nil then
      blockers[#blockers + 1] = blocker("build " .. identity, where, "is an included build the model names no"
                                        .. " directory for")
    elseif record.block[GRADLE_PLUGINS] ~= nil then
      blockers[#blockers + 1] = blocker("build " .. identity, where, "supplies plugins and is depended on as well,"
                                        .. " and a gradlePlugins build is only applied")
    else
      dirs[#dirs + 1] = record.dir
    end
  end
  if #dirs == 0 then return nil end
  return dirs
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
  translation.config.requiresBuilds = required_builds_of(translation, context.by_identity, where, blockers)
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

--- The subprojects that become modules, sorted, and the blockers for those that cannot.
local function module_projects(model, options, blockers)
  local modules, names = {}, {}
  for index = 2, #model.projects do
    local project = model.projects[index]
    if is_java(project) then
      local problem = name_problem(project.dir, project.path)
      if problem ~= nil then
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

local function module_requires(translation, module_of_path, where, blockers)
  local requires = {}
  for _, path in ipairs(translation.requires) do
    local name = module_of_path[path]
    if name == nil then
      blockers[#blockers + 1] = blocker(path, where, "is a project the classpaths hold that becomes no module:"
                                        .. " it applies no Java plugin")
    else
      requires[#requires + 1] = name
    end
  end
  return requires
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
  block.requiresBuilds = required_builds_of(translation, context.by_identity, where, blockers)
  return { name = name, project = project, where = where, block = block, rest = rest, version = translation.version,
           requires = module_requires(translation, context.module_of_path, where, blockers),
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
  local modules, names = module_projects(model, options, blockers)
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
---           builds = { { dir, gradle_name, project, where } }, blockers }
function translate_build.build(model, included_models, options)
  local blockers = {}
  local records, ids, by_identity = included_builds(model, included_models, options, blockers)
  local context = { ids = ids, plugin_builds = plugin_builds_of(records), by_identity = by_identity,
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
  if #records > 0 then
    result.config.builds = {}
    for _, record in ipairs(records) do
      result.config.builds[record.dir] = record.block
      if record.jdk ~= nil and record.jdk ~= result.config.jdk then
        blockers[#blockers + 1] = blocker("jdk", record.where, "differs from the outer build's, and an included"
                                          .. " build runs on the outer build's JDK")
      end
    end
  end
  result.modules = core_modules(result.declared)
  result.builds = records
  result.blockers = blockers
  return result
end

return translate_build
