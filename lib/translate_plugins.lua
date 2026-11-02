--- The third-party plugins a project or the settings apply, translated into
--- `plugins`, `pluginClasspath` and `configure`, or their settings twins.
---
--- @implNote a value the configure tree is not given (a read-only property, a
--- file, a file collection, a source directory set, an empty list or map) is
--- not dropped: `migrate_blockers.extension_differences`
--- compares the extension in the generated build with the old one, so such a
--- value either comes out the same there or blocks.
local translate_plugins = {}

local translation_state = daukle.require("lib/translation")
local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")
local extension_defaults = daukle.require("lib/extension_defaults")
local core_plugins = daukle.require("lib/core_plugins")
local migrate_task_values = daukle.require("lib/migrate_task_values")

local block = translation_state.block
local carried = translation_state.carried
local is_unrendered = translation_state.is_unrendered
local as_set = tables.as_set
local sorted_keys = tables.sorted_keys

local UNCOVERED_ROW = migrate_surface.UNCOVERED_ROW
local SETTINGS_PLUGINS_ROW = migrate_surface.SETTINGS_PLUGINS_ROW
local READ_ONLY = "$readOnly"
local BLOCKS = "$blocks"
local FILE = "$file"
local FILES = "$files"
local SOURCE_DIRECTORIES = "$sourceDirectories"
local PATH_STRING = "$pathString"
local COLLECTIONS = { "$list", "$map" }

--- The keys `daukle/gradle` reads as a marker rather than a block in a
--- configure tree, so a property of that name cannot be said.
local MARKER_KEYS = { file = true, buildOutput = true, env = true, filesOf = true, mapOf = true, putAll = true,
                      addAll = true }

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
--- @param takes_core whether the list takes a core id: a main-build project's does, and neither an
---                   included build's block nor the settings list does
local function plugin_entries(state, plugins, buildscript, takes_core)
  local entries = {}
  for _, plugin in ipairs(plugins or {}) do
    local core_id = takes_core and core_plugins.entry_id(plugin) or nil
    if core_id ~= nil then
      entries[#entries + 1] = { id = core_id }
    elseif plugin.core ~= true and plugin.script == nil then
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
    if value[key] ~= nil then return value[key], key end
  end
  return nil
end

local function is_scalar(value)
  local kind = type(value)
  return kind == "string" or kind == "number" or kind == "boolean"
end

local function all_scalar(collection)
  for _, entry in pairs(collection) do
    if not is_scalar(entry) then return false end
  end
  return true
end

--- The entries a read-only collection holds beyond its plugin's own, as
--- `addAll` or `putAll`, or nil when it holds none or lost one (D-216).
---
--- @implNote a mutation can only add, so a list whose plugin default is not
--- a prefix of it, or a map that drops or changes a default entry, has no
--- spelling; nil leaves it to the comparison, which blocks it there.
local function additions(collection, kind, default)
  local base = type(default) == "table" and default[kind] or {}
  if type(base) ~= "table" then return nil end
  if kind == "$list" then
    for index = 1, #base do
      if not tables.deep_equal(base[index], collection[index]) then return nil end
    end
    if #collection == #base then return nil end
    local added = {}
    for index = #base + 1, #collection do added[#added + 1] = collection[index] end
    return { addAll = added }
  end
  local added = {}
  for key, entry in pairs(base) do
    if not tables.deep_equal(entry, collection[key]) then return nil end
  end
  for key, entry in pairs(collection) do
    if base[key] == nil then added[key] = entry end
  end
  if next(added) == nil then return nil end
  return { putAll = added }
end

--- A collection as a configure value: a plain list as itself, a plain map as
--- `mapOf`, a read-only one as what it adds; anything else blocks by name.
local function collection_value(state, collection, kind, path, read_only, surface, default)
  if next(collection) == nil then return nil end
  if not all_scalar(collection) then
    if not read_only then
      block(state, path, "holds a list or a map whose entries are not plain values, which a configure tree"
            .. " cannot assign", surface)
    end
    return nil
  end
  local entries = {}
  for key, entry in pairs(collection) do
    entries[key] = carried(state, entry, path .. "." .. tostring(key))
    if entries[key] == nil then return nil end
  end
  if read_only then return additions(entries, kind, default) end
  if kind == "$list" then return entries end
  return { mapOf = entries }
end

local configure_tree

--- Whether the plugin's own build holds the same value at the same place, so
--- the old script did not set it. An unrendered value matches only the same
--- marker, which says the plugin built the same kind of object there.
local function is_plugin_default(value, default)
  if default == nil then return false end
  if is_unrendered(value) then return is_unrendered(default) and value["$unrendered"] == default["$unrendered"] end
  return tables.deep_equal(value, default)
end

local function is_identity(value)
  return is_unrendered(value) and value["$unrendered"] == "identity"
end

local function default_at(default, key)
  if type(default) ~= "table" or is_unrendered(default) then return nil end
  return default[key]
end

local function configure_value(state, value, path, read_only, surface, default)
  if is_plugin_default(value, default) then return nil end
  if type(value) ~= "table" then
    if read_only then return nil end
    return carried(state, value, path)
  end
  if is_unrendered(value) then
    block(state, path, "holds a value the model could not render (" .. value["$unrendered"]
          .. "), so it can be neither carried nor left out", surface)
    return nil
  end
  if value[FILE] ~= nil or value[FILES] ~= nil or value[SOURCE_DIRECTORIES] ~= nil then return nil end
  if value[PATH_STRING] ~= nil then
    if not read_only then
      block(state, path, "holds an absolute path of this checkout as text, which a configure tree would"
            .. " carry to every other checkout unchanged", surface)
    end
    return nil
  end
  local collection, kind = collection_of(value)
  if collection ~= nil then return collection_value(state, collection, kind, path, read_only, surface, default) end
  return configure_tree(state, value, path, surface, default)
end

--- Whether a configure tree can open the key as a block. A read-only object
--- the owner has no `key { }` method for is reachable only as a value, so it
--- is left to the comparison (`$blocks`, lib/model_dump.lua).
local function is_wrapper(item)
  for key in pairs(item) do
    if type(key) == "string" and string.sub(key, 1, 1) == "$" and key ~= READ_ONLY and key ~= BLOCKS then return true end
  end
  return false
end

--- @param blocks_only for a task's walk (D-217): an object no `key { }` opens is
--- unreachable even when assignable, because it is a property holding another
--- model object (a publication), which a block would not configure.
local function is_unreachable_block(item, read_only, blocks, blocks_only)
  if type(item) ~= "table" or is_wrapper(item) or blocks then return false end
  return read_only or blocks_only == true
end

function configure_tree(state, value, path, surface, default)
  local read_only = as_set(value[READ_ONLY])
  local blocks = as_set(value[BLOCKS])
  local tree = {}
  for _, key in ipairs(sorted_keys(value)) do
    if key ~= READ_ONLY and key ~= BLOCKS and not is_unreachable_block(value[key], read_only[key], blocks[key], state.blocks_only) then
      local key_path = path .. "." .. key
      local item = configure_value(state, value[key], key_path, read_only[key], surface, default_at(default, key))
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

--- One configure block per extension the walk rendered, third-party or core, less what
--- the defaults build holds (lib/extension_defaults); none at all with SKIP.
--- @implNote an extension whose walk found no public property arrives as its
--- `toString`, an identity rather than a value: whatever state it holds has an
--- unknown origin, so it blocks rather than passing as empty.
--- @param defaults the same build's extensions in the defaults build, SKIP, or nil
local function configure_of(state, extensions, label, surface, defaults)
  if defaults == extension_defaults.SKIP then return nil end
  local configure = {}
  for _, name in ipairs(sorted_keys(extensions or {})) do
    local extension = extensions[name]
    local path = label .. "." .. name
    local default = defaults ~= nil and defaults[name] ~= nil and defaults[name].value or nil
    if (extension.core == true and extension.walked ~= true) or is_plugin_default(extension.value, default) then
      configure[name] = nil
    elseif type(extension.value) == "table" and not is_identity(extension.value) then
      configure[name] = configure_value(state, extension.value, path, false, surface, default)
    elseif extension.value ~= nil then
      block(state, path, "is a third-party extension with no public property the model could read, so"
            .. " whatever it holds can be neither carried nor left out", surface)
    end
  end
  if next(configure) == nil then return nil end
  return configure
end

--- One configure block per task the old build and the defaults build both
--- have, holding what the old build changed (D-217), or nil.
--- @implNote with no defaults build nothing is translated, since every value
--- a plugin set would then read as set; a task only the old build has is its
--- carried code's own, and that code configures it. Nothing here blocks: a
--- task's walk also reads what it derives from other objects (a publication,
--- a launcher), which differs from the defaults build until those are carried,
--- so whether a value still differs is the comparison's to say.
local function task_configure_of(state, project, defaults)
  if defaults == nil or defaults == extension_defaults.SKIP then return nil end
  local lenient = setmetatable({ blocked = {}, blockers = {}, blocks_only = true }, { __index = state })
  local configure = {}
  for _, task in ipairs(project.tasks or {}) do
    local default = defaults[task.name]
    if default ~= nil and type(task.settings) == "table" and not is_unrendered(task.settings) then
      local settings = tables.shallow_copy(task.settings)
      for name in pairs(migrate_task_values.derived(task)) do settings[name] = nil end
      for name in pairs(migrate_task_values.follows_identity(task, project)) do settings[name] = nil end
      configure[task.name] = configure_value(lenient, settings, "configure.tasks." .. task.name, false,
                                             UNCOVERED_ROW, default)
    end
  end
  if next(configure) == nil then return nil end
  return configure
end

--- What the old build set through `Project`'s own setters (`description`,
--- `status`) that the defaults build does not hold, as the reserved
--- `configure.project` block, or nil; nothing with no defaults build, as for a
--- task. An unset value is left to the comparison, which blocks it by name.
local function project_configure_of(state, project, defaults)
  if defaults == nil or defaults == extension_defaults.SKIP or type(project.settings) ~= "table" then return nil end
  local tree = {}
  for _, name in ipairs(sorted_keys(project.settings)) do
    local value = project.settings[name]
    if value ~= nil then
      tree[name] = configure_value(state, value, "configure.project." .. name, false, UNCOVERED_ROW, defaults[name])
    end
  end
  if next(tree) == nil then return nil end
  return tree
end

local function with_reserved(configure, key, value)
  if value == nil then return configure end
  configure = configure or {}
  configure[key] = value
  return configure
end

local function non_empty(list)
  if #list == 0 then return nil end
  return list
end

--- @return { plugins?, pluginClasspath?, configure? }
function translate_plugins.project(state, project)
  local buildscript = project.buildscript or {}
  return {
    plugins = non_empty(plugin_entries(state, project.plugins, buildscript, not state.included)),
    pluginClasspath = non_empty(classpath_of(state, buildscript, "buildscript.classpath", UNCOVERED_ROW)),
    configure = with_reserved(
      with_reserved(configure_of(state, project.extensions, "configure", UNCOVERED_ROW,
                                 extension_defaults.project(state.extension_defaults, state.defaults_build,
                                                            project.path)),
                    "tasks", task_configure_of(state, project,
                                               extension_defaults.tasks(state.extension_defaults, state.defaults_build,
                                                                        project.path))),
      "project", project_configure_of(state, project,
                                      extension_defaults.own(state.extension_defaults, state.defaults_build,
                                                             project.path))),
  }
end

--- @return { settingsPlugins?, settingsPluginClasspath?, settingsConfigure? }
function translate_plugins.settings(state, model)
  local buildscript = model.settingsBuildscript or {}
  return {
    settingsPlugins = non_empty(plugin_entries(state, model.settingsPlugins, buildscript, false)),
    settingsPluginClasspath = non_empty(classpath_of(state, buildscript, "settings buildscript.classpath",
                                                     SETTINGS_PLUGINS_ROW)),
    settingsConfigure = configure_of(state, model.settingsExtensions, "settingsConfigure",
                                     SETTINGS_PLUGINS_ROW,
                                     extension_defaults.settings(state.extension_defaults, state.defaults_build)),
  }
end

return translate_plugins
