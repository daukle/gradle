--- What the `[toolchains.gradle]` keys cannot say about a dumped build, each
--- function returning blockers in core's shape: { construct, where, why, surface? }.
local migrate_blockers = {}

local distributions = daukle.require("lib/distributions")
local migrate_surface = daukle.require("lib/migrate_surface")
local translation = daukle.require("lib/translation")
local tables = daukle.require("lib/tables")
local core_plugins = daukle.require("lib/core_plugins")
local migrate_file_collections = daukle.require("lib/migrate_file_collections")

local blocker = migrate_surface.blocker
local append = tables.append
local is_unrendered = translation.is_unrendered
local BOUNDARY_ROW = migrate_surface.BOUNDARY_ROW
local PACKAGING_ROW = migrate_surface.PACKAGING_ROW
local UNCOVERED_ROW = migrate_surface.UNCOVERED_ROW
local UNKNOWN_SCRIPT = "<unknown script>"

local MAVEN_PUBLISH = "org.gradle.maven-publish"
local PUBLISHING = "org.gradle.publishing"

local CORE_PLUGIN_ROWS = {
  ["org.gradle.war"] = PACKAGING_ROW .. ", the `war` and `ear` plugins",
  ["org.gradle.ear"] = PACKAGING_ROW .. ", the `war` and `ear` plugins",
  ["org.gradle.signing"] = PACKAGING_ROW .. ", `signing`",
  [MAVEN_PUBLISH] = PACKAGING_ROW .. ", `maven-publish`",
  [PUBLISHING] = PACKAGING_ROW .. ", `maven-publish`",
  ["org.gradle.java-test-fixtures"] = migrate_surface.TESTING_ROW .. ", `java-test-fixtures`",
}

--- @implNote the task a `.kts` build's own script plugins register, measured on 7.6.4, 8.13 and 9.6.0;
--- a Groovy build, the generated one included, never has it.
local KOTLIN_SCRIPT_TASK_TYPES = {
  ["org.gradle.kotlin.dsl.accessors.tasks.PrintAccessors"] = true,
}

--- The tasks `publishing` registers: its task types, and the two lifecycle
--- tasks, which are plain `DefaultTask`s known only by name.
local PUBLISHING_TASK_TYPE_PREFIX = "org.gradle.api.publish."
local PUBLISHING_LIFECYCLE_TASKS = { publish = true, publishToMavenLocal = true }

--- @param version the Gradle the wrapper names
function migrate_blockers.unpinned_gradle(version, where)
  return blocker("distributionUrl", where, "names Gradle " .. version .. ", which daukle/gradle does not"
                 .. " pin; the nearest pinned version is " .. distributions.nearest(version)
                 .. ", and moving the build to it is not this migrator's decision, because a Gradle"
                 .. " release can change what a build does", UNCOVERED_ROW)
end

--- @param url the distributionUrl as the wrapper writes it
function migrate_blockers.unreadable_distribution(url, where)
  return blocker("distributionUrl", where, "names no Gradle version this migrator can read (" .. url
                 .. "), and a build that names its Gradle is never moved to a default one", UNCOVERED_ROW)
end

local function known_scripts(scripts)
  local names = {}
  for _, script in ipairs(scripts or {}) do
    if script ~= UNKNOWN_SCRIPT then names[#names + 1] = script end
  end
  if #names == 0 then return "a build script" end
  return table.concat(names, ", ")
end

--- Signal 1: a task whose type or action a build script compiled.
--- @param carried the names of the tasks whose code is carried, which do not block
function migrate_blockers.build_logic(project, where, carried)
  local blockers = {}
  for _, task in ipairs(project.tasks or {}) do
    if task.buildLogic == true and not (carried or {})[task.name] then
      blockers[#blockers + 1] = blocker(task.name, where, "carries code that " .. known_scripts(task.scripts)
                                        .. " compiled (a doFirst, a doLast or a task type the script"
                                        .. " defines), which is build logic written as code", BOUNDARY_ROW)
    end
  end
  return blockers
end

--- The declarations of a settings script the translation reads from the model
--- or the keys carry; anything else in it is code, which has nowhere to go.
local SETTINGS_DECLARATIONS = {
  include = true, includeFlat = true, includeBuild = true, pluginManagement = true, plugins = true,
  dependencyResolutionManagement = true, buildCache = true, toolchainManagement = true,
  enableFeaturePreview = true, buildscript = true,
}

local function settings_head(text)
  if string.match(text, "^rootProject%.name%s*=") or string.match(text, "^rootProject%.buildFileName%s*=") then
    return "rootProject"
  end
  local receiver = string.match(text, "^project%s*%(%s*[\"'][^\"']*[\"']%s*%)%s*%.(%a+)%s*=")
  if receiver == "projectDir" or receiver == "buildFileName" then return "rootProject" end
  return string.match(text, "^[%a_][%w_]*")
end

--- Whether a settings statement is one the translation reads from the model
--- or a key renders, rather than code; an `import` is code, which carried code may need.
function migrate_blockers.is_settings_declaration(statement, extensions)
  local head = settings_head(statement.text)
  return head == "rootProject" or SETTINGS_DECLARATIONS[head] == true or (extensions or {})[head] ~= nil
end

--- A settings script that cannot be read, which blocks because nothing in it
--- can be told from code; every other statement is translated or carried.
function migrate_blockers.settings_code(model, where, directory)
  local script = model.settingsScript
  if script == nil or script.unparsed == nil then return {} end
  local path = directory == nil and script.path or directory .. "/" .. script.path
  return { blocker(path, where, "is a settings script that cannot be read (" .. script.unparsed
                   .. "), so it cannot be told from code", BOUNDARY_ROW) }
end

local function task_names(project)
  local names = {}
  for _, task in ipairs(project.tasks or {}) do names[task.name] = true end
  return names
end

local function applies(project, id)
  for _, plugin in ipairs(project.plugins or {}) do
    for _, plugin_id in ipairs(plugin.ids or {}) do
      if plugin_id == id then return true end
    end
  end
  return false
end

local function is_publishing_task(project, task)
  if not applies(project, PUBLISHING) then return false end
  return string.sub(task.type or "", 1, #PUBLISHING_TASK_TYPE_PREFIX) == PUBLISHING_TASK_TYPE_PREFIX
         or PUBLISHING_LIFECYCLE_TASKS[task.name] == true
end

--- Whether another blocker already explains a task the generated build
--- lacks: signal 1, the `.kts` DSL's own task, or the publishing plugin,
--- which blocks by itself.
local function is_explained(project, task)
  return task.buildLogic == true or KOTLIN_SCRIPT_TASK_TYPES[task.type] or is_publishing_task(project, task)
end

--- The tasks the old project has and the generated build lacks, signal 1's
--- included: what the build script may have registered.
function migrate_blockers.missing_task_names(project, generated)
  local generated_names = task_names(generated)
  local names = {}
  for _, task in ipairs(project.tasks or {}) do
    if not generated_names[task.name] and not KOTLIN_SCRIPT_TASK_TYPES[task.type]
       and not is_publishing_task(project, task) then
      names[#names + 1] = task.name
    end
  end
  return names
end

--- Signal 2: a task the old project has and the build `daukle/gradle`
--- generates from the translated keys lacks.
function migrate_blockers.task_difference(project, generated, where)
  local generated_names = task_names(generated)
  local blockers = {}
  for _, task in ipairs(project.tasks or {}) do
    if not generated_names[task.name] and not is_explained(project, task) then
      blockers[#blockers + 1] = blocker(task.name, where, "is a task the old build has and the build"
                                        .. " daukle/gradle generates from the translated keys does not:"
                                        .. " the build registered it, or a plugin the translation did"
                                        .. " not carry did", BOUNDARY_ROW)
    end
  end
  return blockers
end

local function plugin_name(plugin)
  return (plugin.ids or {})[1] or plugin.type
end

local function carried_plugins(generated)
  local carried = {}
  for id in pairs(core_plugins.IMPLIED) do carried[id] = true end
  for _, plugin in ipairs(generated.plugins or {}) do
    carried[plugin.type] = true
    for _, id in ipairs(plugin.ids or {}) do carried[id] = true end
  end
  return carried
end

local function is_carried(plugin, carried)
  if carried[plugin.type] or core_plugins.KOTLIN_SCRIPT[plugin.type] then return true end
  for _, id in ipairs(plugin.ids or {}) do
    if carried[id] then return true end
  end
  return false
end

--- A core plugin the old project applies that neither the generated build
--- applies nor the keys imply.
function migrate_blockers.core_plugins(project, generated, where)
  local carried = carried_plugins(generated)
  local blockers = {}
  for _, plugin in ipairs(project.plugins or {}) do
    if plugin.core == true and not is_carried(plugin, carried) then
      local name = plugin_name(plugin)
      blockers[#blockers + 1] = blocker(name, where, "is a core Gradle plugin daukle/gradle does not"
                                        .. " model, so nothing it configures has a key",
                                        CORE_PLUGIN_ROWS[name])
    end
  end
  return blockers
end

local function applied_types(plugins)
  local types = {}
  for _, plugin in ipairs(plugins or {}) do types[plugin.type] = true end
  return types
end

local function missing_plugin_reason(plugin)
  if plugin.script ~= nil then
    return "is a plugin class " .. known_scripts({ plugin.script }) .. " compiled, which is build logic written as code"
  end
  return "is a third-party plugin the build daukle/gradle generates from the translated keys does not"
         .. " apply: it has no plugin id, or no jar the classpath resolved carries it"
end

--- A third-party plugin the old build applies and the generated one does not.
--- @param label "" for a project's plugins, "settings " for the settings'
function migrate_blockers.third_party_plugins(plugins, generated_plugins, where, label)
  local generated = applied_types(generated_plugins)
  local blockers = {}
  for _, plugin in ipairs(plugins or {}) do
    if plugin.core ~= true and not generated[plugin.type] then
      blockers[#blockers + 1] = blocker(label .. plugin_name(plugin), where, missing_plugin_reason(plugin),
                                        plugin.script ~= nil and BOUNDARY_ROW or UNCOVERED_ROW)
    end
  end
  return blockers
end

local METADATA = { ["$readOnly"] = true, ["$blocks"] = true }
local WRAPPERS = { ["$list"] = true, ["$map"] = true, ["$file"] = true, ["$files"] = true,
                   ["$sourceDirectories"] = true }

local function union_keys(left, right)
  local seen, keys = {}, {}
  for _, side in ipairs({ left, right }) do
    for key in pairs(side) do
      if not METADATA[key] and not seen[key] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
  end
  table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
  return keys
end

local compare_values

local function compare_tables(old, new, path, differences, directories)
  for _, key in ipairs(union_keys(old, new)) do
    local key_path = WRAPPERS[key] and path or path .. "." .. key
    compare_values(old[key], new[key], key_path, differences, directories)
  end
end

local function is_file_collection(value)
  return type(value) == "table" and type(value["$files"]) == "table"
end

--- @implNote an unrendered old value is skipped, because its caller reports
--- it by name; an unrendered new one is one difference, not one per key.
function compare_values(old, new, path, differences, directories)
  if is_unrendered(old) then return end
  if is_unrendered(new) then
    differences[#differences + 1] = path
  elseif is_file_collection(old) and is_file_collection(new) then
    migrate_file_collections.differences(old["$files"], new["$files"], path, directories, differences)
  elseif type(old) == "table" and type(new) == "table" then
    compare_tables(old, new, path, differences, directories)
  elseif old ~= new then
    differences[#differences + 1] = path
  end
end

local DIFFERS = "differs in the build daukle/gradle generates from the translated keys"

local function difference_blockers(old, new, path, where, why, directories)
  local differences = {}
  compare_values(old, new, path, differences, directories or {})
  local blockers = {}
  for _, difference in ipairs(differences) do
    if type(difference) == "table" then
      blockers[#blockers + 1] = blocker(difference.path, where, why .. "; its entry " .. difference.entry
                                        .. " is only in " .. difference.side, UNCOVERED_ROW)
    else
      blockers[#blockers + 1] = blocker(difference, where, why, UNCOVERED_ROW)
    end
  end
  return blockers
end

--- A walked extension (a third-party one, or a core one the keys do not
--- model) the generated build does not register, or a value of one it does
--- not reproduce: what the configure tree could not carry (a
--- read-only property, a file, a list or a value set through a method),
--- compared leaf by leaf.
--- @param label       "configure" for a project's extensions, "settingsConfigure" for the settings'
--- @param directories { old, new }: each project's build directory, which a file collection's entries are
---                    compared within (lib/migrate_file_collections); nil for the settings'
function migrate_blockers.extension_differences(extensions, generated_extensions, where, label, directories)
  local blockers = {}
  for _, name in ipairs(union_keys(extensions or {}, {})) do
    local extension = extensions[name]
    local path = label .. "." .. name
    local generated = (generated_extensions or {})[name]
    local compared = extension.core ~= true or extension.walked == true
    if compared and generated == nil then
      blockers[#blockers + 1] = blocker(path, where, "is an extension the old build registers and the build"
                                        .. " daukle/gradle generates from the translated keys does not",
                                        UNCOVERED_ROW)
    elseif compared and type(extension.value) == "table" and not is_unrendered(extension.value) then
      append(blockers, difference_blockers(extension.value, generated.value, path, where, DIFFERS
                                           .. ": the old build set it in a way a configure tree does not"
                                           .. " carry (a read-only property, a file, a list or a method call)",
                                           directories))
    end
  end
  return blockers
end

--- Each unrendered leaf under `value`, as { path, why }.
function migrate_blockers.unrendered_paths(value, path, found)
  found = found or {}
  if is_unrendered(value) then
    found[#found + 1] = { path = path, why = value["$unrendered"] }
  elseif type(value) == "table" then
    for _, key in ipairs(union_keys(value, {})) do
      migrate_blockers.unrendered_paths(value[key], path .. "." .. key, found)
    end
  end
  return found
end

local function unreadable_blockers(core, side, where)
  local blockers = {}
  for _, unreadable in ipairs(migrate_blockers.unrendered_paths(core, "settings")) do
    blockers[#blockers + 1] = blocker(unreadable.path, where, "could not be read from " .. side .. " ("
                                      .. unreadable.why .. "), so it cannot be compared", UNCOVERED_ROW)
  end
  return blockers
end

--- The settings blocks compared, without `dependencyResolutionManagement`.
---
--- @implNote its repositories are where a project's rows resolved from, which
--- each pinned entry already names (lib/translation), and its mode only picks
--- between repositories, while the generated build declares none at all; a
--- project's own repositories are not compared either.
local function compared_settings(core)
  local compared = {}
  for key, value in pairs(core or {}) do
    if key ~= "dependencyResolutionManagement" then compared[key] = value end
  end
  return compared
end

--- A core settings block (toolchain repositories, build caches) the
--- generated build does not reproduce, which no key says, or one the dump
--- could not read on either side, `dependencyResolutionManagement` included,
--- which would otherwise compare as equal or pin from nothing.
function migrate_blockers.settings_differences(core, generated_core, where)
  local old, new = compared_settings(core), compared_settings(generated_core)
  local blockers = unreadable_blockers(core or {}, "the old build", where)
  append(blockers, unreadable_blockers(generated_core or {}, "the build daukle/gradle generates", where))
  append(blockers, difference_blockers(old, new, "settings", where, DIFFERS
                                       .. ": it is a block of Gradle's own settings that no daukle/gradle"
                                       .. " key carries"))
  return blockers
end

return migrate_blockers
