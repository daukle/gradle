--- The resolved classpaths of one project's source sets, sorted into the
--- dependency keys that reproduce them, with every other project a classpath
--- reaches recorded as an edge rather than pinned.
---
--- @implNote a row's `via` names the declared edges of its configuration's
--- root it is reachable through. A row reachable only through other projects
--- is left to those projects, whose own keys carry it to this one as Gradle
--- did; a row reachable through an `api` declaration is `api`, so a project
--- consuming this one still compiles against it.
local translate_dependencies = {}

local model_dump = daukle.require("lib/model_dump")
local translation_state = daukle.require("lib/translation")

local block = translation_state.block

local CONFIGURATIONS_ROW = "GRADLE-SURFACE.md: 2. Dependency configurations"
local PROJECT_EDGE = "project "
local MODULE_EDGE = "module "
local GRADLE_PLUGIN_PLUGIN = "org.gradle.java-gradle-plugin"

--- @implNote what `java-gradle-plugin` adds itself, as opaque components with
--- no repository; the generated plugin build applies that plugin too.
local GRADLE_PLUGIN_COMPONENTS = { ["Gradle API"] = true, ["Gradle TestKit"] = true, ["Local Groovy"] = true,
                                   pluginUnderTestMetadata = true }

--- @implNote a project is one row whatever file it resolved to: Gradle hands a
--- compile classpath its classes directory and a runtime classpath its jar.
local function row_key(row)
  if row.kind == "project" then return row.component end
  return row.component .. "\0" .. (row.fileName or "")
end

--- The resolved rows of each configuration, in Gradle's classpath order.
function translate_dependencies.rows_by_configuration(project)
  local rows = {}
  local dependencies = project.dependencies or {}
  for _, row in ipairs(dependencies.resolved or {}) do
    local list = rows[row.configuration]
    if list == nil then
      list = { seen = {} }
      rows[row.configuration] = list
    end
    if not list.seen[row_key(row)] then
      list.seen[row_key(row)] = true
      list[#list + 1] = row
    end
  end
  return rows
end

local function declared_modules(project, configuration)
  local modules = {}
  for _, row in ipairs((project.dependencies or {}).declared or {}) do
    if row.configuration == configuration and row.kind == "module" then
      modules[MODULE_EDGE .. row.group .. ":" .. row.name] = true
    end
  end
  return modules
end

local function is_reached_through(row, edges)
  for _, edge in ipairs(row.via or {}) do
    if edges[edge] then return true end
  end
  return false
end

local function own_edge(row)
  return PROJECT_EDGE .. row.build .. " " .. row.project
end

local function is_project_edge(edge)
  return string.sub(edge, 1, #PROJECT_EDGE) == PROJECT_EDGE
end

--- Whether every edge that reaches the row is another project, which then
--- carries it.
local function is_carried_by_projects(row)
  local via = row.via or {}
  if #via == 0 then return false end
  for _, edge in ipairs(via) do
    if not is_project_edge(edge) or (row.kind == "project" and edge == own_edge(row)) then return false end
  end
  return true
end

local function applies_gradle_plugin_plugin(project)
  for _, plugin in ipairs(project.plugins or {}) do
    for _, id in ipairs(plugin.ids or {}) do
      if id == GRADLE_PLUGIN_PLUGIN then return true end
    end
  end
  return false
end

local function is_gradle_plugin_component(project, row)
  return GRADLE_PLUGIN_COMPONENTS[row.component] == true and applies_gradle_plugin_plugin(project)
end

local function project_name(row)
  if row.build == ":" then return row.project end
  return "build " .. row.build
end

--- An edge to a project another key carries: a module of this build becomes
--- a `requires`, a project of an included build a `requiresBuilds`.
local function record_edge(translation, row)
  if row.build == ":" then
    translation.requires[row.project] = true
  else
    translation.required_builds[row.build] = true
  end
end

local function block_edge(translation, row, place)
  translation.unpinned[row.component] = true
  block(translation, project_name(row), "is a project dependency of " .. place .. ", and requires and"
        .. " requiresBuilds put a project on main's compile and runtime classpaths only", CONFIGURATIONS_ROW)
end

local function append_pin(translation, project, buckets, key, row)
  local pin = translation_state.pin_of(translation, project.repositories, row)
  if pin == nil then return end
  buckets[key] = buckets[key] or {}
  buckets[key][#buckets[key] + 1] = pin
end

--- Pins one row into `key`, or leaves it to the project that carries it.
--- @param place how a refusal names where an edge sits, or nil where an edge becomes a key
local function place_row(translation, project, buckets, key, row, place)
  if row.kind == "project" then
    if place == nil then
      record_edge(translation, row)
    elseif not is_carried_by_projects(row) then
      block_edge(translation, row, place)
    end
    return
  end
  if is_carried_by_projects(row) or is_gradle_plugin_component(project, row) then return end
  append_pin(translation, project, buckets, key, row)
end

--- Each artifact a set's classpaths resolve to, sorted into the bucket that
--- reproduces them: on both compile and runtime, compile only, runtime only.
--- `inherited` maps each bucket to the artifacts the set already sees through
--- main, which are left out of it.
local function split_classpaths(rows, set, inherited)
  local compile = rows[set.compileClasspath] or { seen = {} }
  local runtime = rows[set.runtimeClasspath] or { seen = {} }
  local split = { both = {}, compile = {}, runtime = {}, processor = {} }
  for _, row in ipairs(compile) do
    local bucket = runtime.seen[row_key(row)] and "both" or "compile"
    if not inherited[bucket][row_key(row)] then split[bucket][#split[bucket] + 1] = row end
  end
  for _, row in ipairs(runtime) do
    if not compile.seen[row_key(row)] and not inherited.runtime[row_key(row)] then
      split.runtime[#split.runtime + 1] = row
    end
  end
  for _, row in ipairs(rows[set.annotationProcessor] or {}) do split.processor[#split.processor + 1] = row end
  return split
end

local function keys_of(rows)
  local keys = {}
  for _, row in ipairs(rows) do keys[row_key(row)] = true end
  return keys
end

local function union(...)
  local out = {}
  for _, set in ipairs({ ... }) do
    for key in pairs(set) do out[key] = true end
  end
  return out
end

local NOTHING_INHERITED = { both = {}, compile = {}, runtime = {} }

--- @return the buckets keyed by manifest key, and main's rows by bucket for test to inherit
function translate_dependencies.main(translation, project, rows, set)
  local split = split_classpaths(rows, set, NOTHING_INHERITED)
  local api = declared_modules(project, "api")
  local compile_only_api = declared_modules(project, "compileOnlyApi")
  local buckets = {}
  for _, row in ipairs(split.both) do
    place_row(translation, project, buckets, is_reached_through(row, api) and "api" or "classpath", row, nil)
  end
  for _, row in ipairs(split.compile) do
    place_row(translation, project, buckets,
              is_reached_through(row, compile_only_api) and "compileOnlyApi" or "compileOnly", row,
              "the compile classpath only")
  end
  for _, row in ipairs(split.runtime) do
    place_row(translation, project, buckets, "runtimeOnly", row, "the runtime classpath only")
  end
  for _, row in ipairs(split.processor) do
    place_row(translation, project, buckets, "annotationProcessor", row, "an annotation processor path")
  end
  return buckets, split
end

--- @implNote test sees main's `implementation` and `api` on both classpaths and
--- main's `runtimeOnly` at runtime, so those are not repeated in test's keys.
--- The launcher the dump resolved for a JUnit Platform engine goes to
--- `testRuntimeOnly`, where Gradle 8 put it at test time.
function translate_dependencies.test(translation, project, rows, set, main_split)
  local both = keys_of(main_split.both)
  local inherited = { both = both, compile = both, runtime = union(both, keys_of(main_split.runtime)) }
  local split = split_classpaths(rows, set, inherited)
  local buckets = {}
  local keys = { both = "testClasspath", compile = "testCompileOnly", runtime = "testRuntimeOnly",
                 processor = "testAnnotationProcessor" }
  for bucket, key in pairs(keys) do
    for _, row in ipairs(split[bucket]) do
      place_row(translation, project, buckets, key, row, "a test classpath only")
    end
  end
  for _, row in ipairs(rows[model_dump.IMPLIED_LAUNCHER] or {}) do
    append_pin(translation, project, buckets, "testRuntimeOnly", row)
  end
  return buckets
end

function translate_dependencies.custom(translation, project, rows, name, set)
  local split = split_classpaths(rows, set, NOTHING_INHERITED)
  local buckets = {}
  local keys = { both = "classpath", compile = "compileOnly", runtime = "runtimeOnly",
                 processor = "annotationProcessor" }
  for bucket, key in pairs(keys) do
    for _, row in ipairs(split[bucket]) do
      place_row(translation, project, buckets, key, row, "source set " .. name)
    end
  end
  return buckets
end

return translate_dependencies
