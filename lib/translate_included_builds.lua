--- The included builds of a dumped build, each translated into a
--- `builds.<dir>` block, and the edges a project's classpaths hold to them.
---
--- @implNote an included build's `group` and `version` are not carried: the
--- outer build reached it through a coordinate Gradle substituted, and the
--- generated build substitutes `daukle.included:<name>` instead, so neither
--- names anything the outer build's output holds.
local translate_included_builds = {}

local translate_model = daukle.require("lib/translate_model")
local translation_state = daukle.require("lib/translation")
local module_graph = daukle.require("lib/modules")
local builds = daukle.require("lib/builds")

local SURFACE = "GRADLE-SURFACE.md: "
local UNCOVERED_ROW = SURFACE .. "6. What this file does NOT yet cover, said plainly"
local GRADLE_PLUGINS = "gradlePlugins"
local ROOT_PATH = ":"
local CURRENT_BUILD = ":"

local function blocker(construct, where, why)
  return { construct = construct, where = where, why = why, surface = UNCOVERED_ROW }
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

local function split_keys(config, keep)
  local kept, rest = {}, {}
  for key, value in pairs(config) do
    if keep[key] then kept[key] = value else rest[key] = value end
  end
  return kept, rest
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
function translate_included_builds.directory_problem(dir, path)
  if not is_inside(dir) then return "lies at " .. tostring(dir) .. ", outside the project's root" end
  local problem = module_graph.problem_of(dir)
  if problem ~= nil then return "lies in a directory whose name " .. problem end
  if path ~= nil and gradle_path(dir) ~= path then
    return "lies in " .. dir .. ", and with modules a project's Gradle path is its directory's, " .. gradle_path(dir)
  end
  return nil
end

--- One `gradlePlugins` entry, or nil when the model holds no readable id
--- and class or either holds an environment value.
local function gradle_plugin_entry(state, construct, plugin)
  if type(plugin.id) ~= "string" or type(plugin.implementationClass) ~= "string" then
    translation_state.block(state, construct, "names no id or implementation class the model could read",
                            UNCOVERED_ROW)
    return nil
  end
  if plugin.displayName ~= nil or plugin.description ~= nil then
    translation_state.block(state, construct, "sets a display name or a description, which a gradlePlugins"
                            .. " entry cannot carry", UNCOVERED_ROW)
  end
  local id = translation_state.carried(state, plugin.id, construct .. ".id")
  local class = translation_state.carried(state, plugin.implementationClass, construct .. ".implementationClass")
  if id == nil or class == nil then return nil end
  return { id = id, implementationClass = class }
end

local function gradle_plugins_of(project, state)
  local extension = (project.extensions or {}).gradlePlugin
  local value = extension ~= nil and extension.value or nil
  if type(value) ~= "table" or type(value.plugins) ~= "table" then return nil end
  local entries = {}
  for _, name in ipairs(sorted_keys(value.plugins)) do
    local entry = gradle_plugin_entry(state, "gradlePlugin.plugins." .. name, value.plugins[name])
    if entry ~= nil then entries[#entries + 1] = entry end
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

local function shape_problem(model)
  if model == nil then
    return "has no dumped model: the init script never reached its whenReady, so nothing it holds can be translated"
  end
  if #(model.projects or {}) ~= 1 then return "has subprojects, and an included build block describes one project" end
  if #(model.includedBuilds or {}) > 0 then return "includes builds of its own" end
  if has_third_party(model.settingsPlugins) then
    return "applies settings plugins of its own, which a build block cannot say"
  end
  return nil
end

local function block_extra_keys(rest, where, blockers)
  for _, key in ipairs(sorted_keys(rest)) do
    if key ~= "jdk" then
      blockers[#blockers + 1] = blocker(key, where, "is set in an included build, and an included build block"
                                        .. " takes only source roots, release and dependency keys")
    end
  end
end

--- One included build's root project as a `builds.<dir>` block, or nil and
--- the reason it cannot be one.
local function included_block(entry, model, options, blockers)
  local problem = shape_problem(model)
  if problem ~= nil then return nil, problem end
  local project = model.projects[1]
  local where = within(options.dir, entry.dir .. "/" .. (project.buildFile or "."))
  local build = { model = model, dir = options.dir, where = where, prefix = entry.dir .. "/", name = entry.dir }
  local translation = translate_model.project(project, build)
  append(blockers, translation.blockers)
  local block, rest = split_keys(translation.config, builds.KEYS)
  block_extra_keys(rest, where, blockers)
  if #translation.requiredBuilds > 0 then
    blockers[#blockers + 1] = blocker("requiresBuilds", where, "is an included build that depends on another"
                                      .. " included build, which a build block cannot say")
  end
  local state = translation_state.new(build)
  block[GRADLE_PLUGINS] = gradle_plugins_of(project, state)
  append(blockers, state.blockers)
  return { dir = entry.dir, gradle_name = (string.gsub(entry.dir, "/", "-")), project = project, where = where,
           block = block, jdk = rest.jdk, unpinned = translation.unpinned,
           identity = CURRENT_BUILD .. entry.name }
end

--- @param included_models the included builds' models, by the name `includedBuilds` gives them
--- @param options         { dir = <context.dir>, settings = <the settings file, relative to dir> }
--- @return { records, ids = <set of the plugin ids they declare>, plugin_builds = <set of identity paths>,
---           by_identity = <old identity path -> record> }
function translate_included_builds.read(model, included_models, options, blockers)
  local read = { records = {}, ids = {}, plugin_builds = {}, by_identity = {} }
  local settings = within(options.dir, options.settings)
  for _, entry in ipairs(model.includedBuilds or {}) do
    local problem = translate_included_builds.directory_problem(entry.dir, nil)
    local record = nil
    if problem == nil then record, problem = included_block(entry, included_models[entry.name], options, blockers) end
    if problem ~= nil then
      blockers[#blockers + 1] = blocker(tostring(entry.dir), settings, "is an included build that " .. problem)
    else
      read.records[#read.records + 1] = record
      read.by_identity[record.identity] = record
      for _, plugin in ipairs(record.block[GRADLE_PLUGINS] or {}) do read.ids[plugin.id] = true end
      if record.block[GRADLE_PLUGINS] ~= nil then read.plugin_builds[record.identity] = true end
    end
  end
  return read
end

--- The included builds a project's main classpaths hold, by directory; one
--- that supplies plugins blocks, because a plugin build is applied, not
--- depended on.
function translate_included_builds.required(translation, by_identity, where, blockers)
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

--- The `builds` key, with a blocker for a build whose own JDK is not the
--- outer build's, which it runs on.
function translate_included_builds.config(records, jdk, blockers)
  if #records == 0 then return nil end
  local config = {}
  for _, record in ipairs(records) do
    config[record.dir] = record.block
    if record.jdk ~= nil and record.jdk ~= jdk then
      blockers[#blockers + 1] = blocker("jdk", record.where, "differs from the outer build's, and an included"
                                        .. " build runs on the outer build's JDK")
    end
  end
  return config
end

return translate_included_builds
