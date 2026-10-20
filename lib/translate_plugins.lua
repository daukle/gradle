--- The third-party plugins a project or the settings apply, translated into
--- `plugins`, `pluginClasspath` and `configure`, or their settings twins.
---
--- @implNote a value the configure tree is not given (a read-only property, a
--- file, an empty list or map) is not dropped: `migrate_blockers.extension_differences`
--- compares the extension in the generated build with the old one, so such a
--- value either comes out the same there or blocks.
local translate_plugins = {}

local translation_state = daukle.require("lib/translation")
local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")

local block = translation_state.block
local carried = translation_state.carried
local is_unrendered = translation_state.is_unrendered
local as_set = tables.as_set
local sorted_keys = tables.sorted_keys

local UNCOVERED_ROW = migrate_surface.UNCOVERED_ROW
local SETTINGS_PLUGINS_ROW = migrate_surface.SETTINGS_PLUGINS_ROW
local READ_ONLY = "$readOnly"
local FILE = "$file"
local COLLECTIONS = { "$list", "$map" }

--- The keys `daukle/gradle` reads as a marker rather than a block in a
--- configure tree, so a property of that name cannot be said.
local MARKER_KEYS = { file = true, buildOutput = true, env = true }

local function is_plugin_build_edge(state, edge)
  local build = string.match(edge, "^project (%S+) ")
  return build ~= nil and state.included_plugin_builds[build] == true
end

--- @implNote a plugin an included build supplies reaches the classpath as
--- that build's project, with that build's own dependencies behind it, and a
--- versionless `plugins` entry plus the build's block carry both instead.
local function is_included_plugin_build(state, row)
  if row.kind == "project" then return state.included_plugin_builds[row.build] == true end
  local via = row.via or {}
  if #via == 0 then return false end
  for _, edge in ipairs(via) do
    if not is_plugin_build_edge(state, edge) then return false end
  end
  return true
end

local function classpath_of(state, buildscript, key, surface)
  for _, failure in ipairs(buildscript.errors or {}) do
    block(state, key, "could not be resolved in the old build: " .. failure.error, surface)
  end
  local pins = {}
  for _, row in ipairs(buildscript.resolved or {}) do
    if not is_included_plugin_build(state, row) then
      local pin = translation_state.pin_of(state, buildscript.repositories, row)
      if pin ~= nil then pins[#pins + 1] = pin end
    end
  end
  return pins
end

local function jar_row_in(rows, jar)
  for _, row in ipairs(rows or {}) do
    if row.kind == "module" and row.fileName == jar then return row end
  end
  return nil
end

--- @implNote a subproject applies a plugin from its ancestors' classloader as
--- well as from its own, so their resolved rows are looked in too.
local function jar_row(state, buildscript, jar)
  return jar_row_in(buildscript.resolved, jar) or jar_row_in(state.inherited_buildscript, jar)
end

local function included_id(state, plugin)
  for _, id in ipairs(plugin.ids or {}) do
    if state.included_plugin_ids[id] then return id end
  end
  return nil
end

local function pinned_entry(state, plugin, buildscript)
  local id = (plugin.ids or {})[1]
  local row = plugin.jar ~= nil and jar_row(state, buildscript, plugin.jar) or nil
  if id == nil or row == nil then return nil end
  local carried_id = carried(state, id, id)
  local version = carried(state, row.version, id)
  if carried_id == nil or version == nil then return nil end
  return { id = carried_id, version = version }
end

--- @implNote only a plugin with an id, applied from a jar this classpath
--- resolved, can be a pinned entry, and one whose id an included build
--- declares a versionless entry; any other third-party plugin is either
--- applied by one of those in the generated build too or blocks there
--- (`migrate_blockers.third_party_plugins`). The version is the jar's, which
--- is the one the pinned url carries.
local function plugin_entries(state, plugins, buildscript)
  local entries = {}
  for _, plugin in ipairs(plugins or {}) do
    if plugin.core ~= true and plugin.script == nil then
      local included = included_id(state, plugin)
      local entry = included ~= nil and { id = carried(state, included, included) }
                    or pinned_entry(state, plugin, buildscript)
      if entry ~= nil and entry.id ~= nil then entries[#entries + 1] = entry end
    end
  end
  return entries
end

local function collection_of(value)
  for _, key in ipairs(COLLECTIONS) do
    if value[key] ~= nil then return value[key] end
  end
  return nil
end

local configure_tree

local function configure_value(state, value, path, read_only, surface)
  if type(value) ~= "table" then
    if read_only then return nil end
    return carried(state, value, path)
  end
  if is_unrendered(value) then
    block(state, path, "holds a value the model could not render (" .. value["$unrendered"]
          .. "), so it can be neither carried nor left out", surface)
    return nil
  end
  if value[FILE] ~= nil then return nil end
  local collection = collection_of(value)
  if collection ~= nil then
    if not read_only and next(collection) ~= nil then
      block(state, path, "holds a list or a map, which a configure tree cannot assign", surface)
    end
    return nil
  end
  return configure_tree(state, value, path, surface)
end

function configure_tree(state, value, path, surface)
  local read_only = as_set(value[READ_ONLY])
  local tree = {}
  for _, key in ipairs(sorted_keys(value)) do
    if key ~= READ_ONLY then
      local key_path = path .. "." .. key
      local item = configure_value(state, value[key], key_path, read_only[key], surface)
      if item ~= nil and MARKER_KEYS[key] then
        block(state, key_path, "is a property named like a configure marker, which daukle/gradle"
              .. " reads as a marker rather than a value", surface)
      elseif item ~= nil then
        tree[key] = item
      end
    end
  end
  if next(tree) == nil then return nil end
  return tree
end

--- One configure block per third-party extension the walk rendered.
--- @implNote an extension whose walk found no public property arrives as its
--- `toString`, an identity rather than a value: whatever state it holds has an
--- unknown origin, so it blocks rather than passing as empty.
local function configure_of(state, extensions, label, surface)
  local configure = {}
  for _, name in ipairs(sorted_keys(extensions or {})) do
    local extension = extensions[name]
    local path = label .. "." .. name
    if extension.core ~= true and type(extension.value) == "table" then
      configure[name] = configure_value(state, extension.value, path, false, surface)
    elseif extension.core ~= true and extension.value ~= nil then
      block(state, path, "is a third-party extension with no public property the model could read, so"
            .. " whatever it holds can be neither carried nor left out", surface)
    end
  end
  if next(configure) == nil then return nil end
  return configure
end

local function non_empty(list)
  if #list == 0 then return nil end
  return list
end

--- @return { pluginClasspath? }
function translate_plugins.classpath(state, project)
  local buildscript = project.buildscript or {}
  return { pluginClasspath = non_empty(classpath_of(state, buildscript, "buildscript.classpath", UNCOVERED_ROW)) }
end

--- @return { plugins?, pluginClasspath?, configure? }
function translate_plugins.project(state, project)
  local buildscript = project.buildscript or {}
  return {
    plugins = non_empty(plugin_entries(state, project.plugins, buildscript)),
    pluginClasspath = non_empty(classpath_of(state, buildscript, "buildscript.classpath", UNCOVERED_ROW)),
    configure = configure_of(state, project.extensions, "configure", UNCOVERED_ROW),
  }
end

--- @return { settingsPlugins?, settingsPluginClasspath?, settingsConfigure? }
function translate_plugins.settings(state, model)
  local buildscript = model.settingsBuildscript or {}
  return {
    settingsPlugins = non_empty(plugin_entries(state, model.settingsPlugins, buildscript)),
    settingsPluginClasspath = non_empty(classpath_of(state, buildscript, "settings buildscript.classpath",
                                                     SETTINGS_PLUGINS_ROW)),
    settingsConfigure = configure_of(state, model.settingsExtensions, "settingsConfigure",
                                     SETTINGS_PLUGINS_ROW),
  }
end

return translate_plugins
