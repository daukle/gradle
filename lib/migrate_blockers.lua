--- What the `[toolchains.gradle]` keys cannot say about a dumped build, each
--- function returning blockers in core's shape: { construct, where, why, surface? }.
local migrate_blockers = {}

local distributions = daukle.require("lib/distributions")

local SURFACE = "GRADLE-SURFACE.md: "
local BOUNDARY_ROW = SURFACE .. 'The boundary: what "100% of Gradle" does not include'
local PACKAGING_ROW = SURFACE .. "4. Packaging and publishing"
local UNCOVERED_ROW = SURFACE .. "6. What this file does NOT yet cover, said plainly"
local UNKNOWN_SCRIPT = "<unknown script>"

local CORE_PLUGIN_ROWS = {
  ["org.gradle.war"] = PACKAGING_ROW .. ", the `war` and `ear` plugins",
  ["org.gradle.ear"] = PACKAGING_ROW .. ", the `war` and `ear` plugins",
  ["org.gradle.signing"] = PACKAGING_ROW .. ", `signing`",
  ["org.gradle.java-test-fixtures"] = SURFACE .. "5. Testing, `java-test-fixtures`",
}

--- The core plugins the keys imply beyond what the generated build applies:
--- `java-library` renders only when an api key is set, `application` only
--- with a main class, and `maven-publish` is carried by name (spec section 5).
--- `publishing` and `distribution` are what the last two apply themselves.
local IMPLIED_CORE_PLUGINS = {
  ["org.gradle.java"] = true,
  ["org.gradle.java-library"] = true,
  ["org.gradle.application"] = true,
  ["org.gradle.maven-publish"] = true,
  ["org.gradle.publishing"] = true,
  ["org.gradle.distribution"] = true,
}

--- @implNote a `.kts` build's own script plugins report as core plugins and
--- are the DSL's, not the build's (spec section 5).
local KOTLIN_SCRIPT_PLUGINS = {
  ["org.gradle.kotlin.dsl.provider.plugins.KotlinScriptBasePlugin"] = true,
  ["org.gradle.kotlin.dsl.provider.plugins.KotlinScriptRootPlugin"] = true,
}

--- @implNote the task those plugins register, measured on 7.6.4, 8.13 and 9.6.0;
--- a Groovy build, the generated one included, never has it.
local KOTLIN_SCRIPT_TASK_TYPES = {
  ["org.gradle.kotlin.dsl.accessors.tasks.PrintAccessors"] = true,
}

local function blocker(construct, where, why, surface)
  return { construct = construct, where = where, why = why, surface = surface }
end

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

local function script_names(task)
  local names = {}
  for _, script in ipairs(task.scripts or {}) do
    if script ~= UNKNOWN_SCRIPT then names[#names + 1] = script end
  end
  if #names == 0 then return "a build script" end
  return table.concat(names, ", ")
end

--- Signal 1: a task whose type or action a build script compiled.
function migrate_blockers.build_logic(project, where)
  local blockers = {}
  for _, task in ipairs(project.tasks or {}) do
    if task.buildLogic == true then
      blockers[#blockers + 1] = blocker(task.name, where, "carries code that " .. script_names(task)
                                        .. " compiled (a doFirst, a doLast or a task type the script"
                                        .. " defines), which is build logic written as code", BOUNDARY_ROW)
    end
  end
  return blockers
end

local function task_names(project)
  local names = {}
  for _, task in ipairs(project.tasks or {}) do names[task.name] = true end
  return names
end

--- Signal 2: a task the old project has and the build `daukle/gradle`
--- generates from the translated keys lacks.
---
--- @implNote a task signal 1 already blocked is left out, so one cause is
--- reported once.
function migrate_blockers.task_difference(project, generated, where)
  local generated_names = task_names(generated)
  local blockers = {}
  for _, task in ipairs(project.tasks or {}) do
    local explained = task.buildLogic == true or KOTLIN_SCRIPT_TASK_TYPES[task.type]
    if not generated_names[task.name] and not explained then
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
  for id in pairs(IMPLIED_CORE_PLUGINS) do carried[id] = true end
  for _, plugin in ipairs(generated.plugins or {}) do
    carried[plugin.type] = true
    for _, id in ipairs(plugin.ids or {}) do carried[id] = true end
  end
  return carried
end

local function is_carried(plugin, carried)
  if carried[plugin.type] or KOTLIN_SCRIPT_PLUGINS[plugin.type] then return true end
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

return migrate_blockers
