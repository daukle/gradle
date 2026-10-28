--- What a migration carries of the old build's code: per project and included
--- build, the statements lib/migrate_logic selects, the `logic` key naming
--- their file, the file's text for core to write, and the tasks they account
--- for, which signal 1 no longer blocks (spec D-165, sections 4.1, 4.3, 4.5).
local migrate_carry = {}

local migrate_logic = daukle.require("lib/migrate_logic")
local migrate_blockers = daukle.require("lib/migrate_blockers")
local migrate_surface = daukle.require("lib/migrate_surface")
local translate_build = daukle.require("lib/translate_build")
local carried = daukle.require("lib/carried")
local composite = daukle.require("lib/composite")
local groovy = daukle.require("lib/groovy")
local tables = daukle.require("lib/tables")

local append = tables.append
local MAIN_BUILD = "root"
local ROOT_PATH = ":"
local GROOVY = "groovy"

local function boundary_blocker(construct, where, why)
  return migrate_surface.blocker(construct, where, why, migrate_surface.BOUNDARY_ROW)
end

local function by_path(model)
  local projects = {}
  for _, project in ipairs((model or {}).projects or {}) do projects[project.path] = project end
  return projects
end

--- Every project a `logic` key can be set for, with what places it: the main
--- build's root or module, or an included build's root.
---
--- @return { { project, where, counterpart, build, place, label, gradle_build } }
local function targets(built, generated, generated_models)
  local list, generated_projects = {}, by_path(generated)
  for _, entry in ipairs(built.projects) do
    list[#list + 1] = { project = entry.project, where = entry.where, build = MAIN_BUILD, gradle_build = "",
                        counterpart = generated_projects[entry.project.path], label = entry.project.path,
                        place = { module = entry.module, root = entry.project.path == ROOT_PATH } }
  end
  for _, record in ipairs(built.builds) do
    local counterpart = generated_models[record.dir]
    list[#list + 1] = { project = record.project, where = record.where, build = record.dir,
                        gradle_build = record.gradle_name, label = record.identity,
                        counterpart = counterpart ~= nil and counterpart.model.projects[1] or nil,
                        place = { build = record.dir } }
  end
  return list
end

local function dsl_of(project)
  return (project.script or {}).dsl or GROOVY
end

local function shown_path(target, task)
  if target.place.build == nil then return task.path end
  return target.label .. task.path
end

--- The carried tasks the old project has: their path within their build, the
--- Gradle name of that build ("" for the main one), and the path the report shows.
local function carried_task_paths(target, covered)
  local paths = {}
  for _, task in ipairs(target.project.tasks or {}) do
    if covered[task.name] then
      paths[#paths + 1] = { build = target.gradle_build, path = task.path, shown = shown_path(target, task) }
    end
  end
  return paths
end

local function no_place_blocker(target)
  return boundary_blocker(target.project.path, target.where, "holds build logic the migration would carry, and"
                          .. " it becomes no module, so there is no project to carry it into")
end

local function duplicate_blocker(target, path)
  return boundary_blocker(path, target.where, "would hold the build logic of two projects, " .. target.label
                          .. " among them, so neither is carried")
end

local function new_result()
  return { files = {}, texts = {}, covered = {}, tasks = {}, blockers = {}, withheld = {} }
end

--- @implNote a project whose carried code reads a version catalog carries
--- none of it: the render carrying it would fail on the unresolved accessor
--- and take every other build's comparison with it (D-194). Its tasks count
--- as covered, because the catalog blocker already names why they are absent.
local function withhold(target, selection, result)
  result.covered[target.project] = selection.covered
  result.withheld[target.project] = true
end

local function carry_target(target, config, instance, result, taken)
  local missing = target.counterpart ~= nil
                  and migrate_blockers.missing_task_names(target.project, target.counterpart) or {}
  local selection = migrate_logic.select(target.project, missing, target.where)
  append(result.blockers, selection.blockers)
  if #selection.carried == 0 then return end
  if selection.reads_catalog then return withhold(target, selection, result) end
  local dsl = dsl_of(target.project)
  local path = migrate_logic.file_path(target.build, target.project.path, dsl, instance)
  if taken[path] then
    result.blockers[#result.blockers + 1] = duplicate_blocker(target, path)
    return
  end
  if not translate_build.set_logic(config, target.place, path) then
    result.blockers[#result.blockers + 1] = no_place_blocker(target)
    return
  end
  taken[path] = true
  local text = migrate_logic.text(selection.carried, dsl, (target.project.script or {}).lineEnding)
  result.files[#result.files + 1] = { path = path, text = text }
  result.texts[path] = text
  result.covered[target.project] = selection.covered
  append(result.tasks, carried_task_paths(target, selection.covered))
end

--- Selects what every project carries, setting its `logic` key in
--- `built.config`.
---
--- @param generated        the generated root build's model, rendered without carried code
--- @param generated_models the generated included builds' models, by directory
--- @param instance         the toolchain instance migrated to
--- @return { files = { { path, text } }, texts = path -> text, covered = project -> set of task names,
---           tasks = { { build, path, shown } }, blockers, withheld = set of projects carrying nothing }
function migrate_carry.select(built, generated, generated_models, instance)
  local result, taken = new_result(), {}
  for _, target in ipairs(targets(built, generated, generated_models)) do
    carry_target(target, built.config, instance, result, taken)
  end
  return result
end

local function derived_root_of(context, place)
  local root = carried.derived_of(context.instance)
  if place.build ~= nil then return root .. "/" .. composite.path_of(place.build) end
  return root
end

--- Each derived root an earlier carrying render linked to the real tree, as
--- the place whose `logic` key renders it carrying, and its derived root.
---
--- @implNote a render without logic would write through those links into the
--- user's own files, so the comparison's first render must carry there too.
function migrate_carry.linked_roots(context, built)
  local linked = {}
  local places = { { root = true } }
  for _, record in ipairs(built.builds) do places[#places + 1] = { build = record.dir } end
  for _, place in ipairs(places) do
    local derived_root = derived_root_of(context, place)
    if carried.is_linked(derived_root) then linked[#linked + 1] = { place = place, derived_root = derived_root } end
  end
  return linked
end

--- The config the first render reads: the translation's, with an empty
--- carried file wherever a derived root is linked, so nothing is written
--- through a link and the task set is the one the keys alone give.
---
--- @return the config, and the carried texts it names
function migrate_carry.baseline_config(config, linked, instance)
  local copy, texts = {}, {}
  for key, value in pairs(config) do copy[key] = value end
  if config.builds ~= nil then
    copy.builds = {}
    for name, block in pairs(config.builds) do
      copy.builds[name] = {}
      for key, value in pairs(block) do copy.builds[name][key] = value end
    end
  end
  for _, entry in ipairs(linked) do
    local build = entry.place.build or MAIN_BUILD
    local path = migrate_logic.file_path(build, ROOT_PATH, GROOVY, instance)
    translate_build.set_logic(copy, entry.place, path)
    texts[path] = ""
  end
  return copy, texts
end

local function carries_at(config, place)
  if place.build ~= nil then return ((config.builds or {})[place.build] or {}).logic ~= nil end
  return carried.build_carries(config)
end

--- A linked derived root the final config renders without logic: the proof
--- would write through its links, so the migration blocks there.
function migrate_carry.stale_link_blockers(config, linked)
  local blockers = {}
  for _, entry in ipairs(linked) do
    if not carries_at(config, entry.place) then
      blockers[#blockers + 1] = boundary_blocker(entry.derived_root, entry.derived_root, "holds links to the"
        .. " project's own files that an earlier migration placed, and this migration carries no build logic"
        .. " there, so its proof would write through them: remove " .. entry.derived_root
        .. " and run daukle migrate again")
    end
  end
  return blockers
end

--- The init script `gradle:jars` adds while it is not empty, and empties once
--- run: the proof that follows a migration is that task's first run.
migrate_carry.REPORT_SCRIPT = carried.MIGRATE_PREFIX .. "carried-tasks.gradle"

local NOT_RUN = ": carried, configured and compared, not run by the proof"

--- The report script's text, which names each carried task the proof's task
--- graph does not hold; empty when nothing is carried.
---
--- @implNote decided by the graph the proof itself schedules, in each build
--- of the composite, rather than guessed from task types: carried code can
--- make a jar depend on anything.
function migrate_carry.report_script(tasks)
  if #tasks == 0 then return "" end
  local lines = { "// Generated by daukle/gradle for the proof of a migration. Do not edit.",
                  "def daukleCarried = [" }
  for _, task in ipairs(tasks) do
    lines[#lines + 1] = "  [" .. groovy.quoted(task.build) .. ", " .. groovy.quoted(task.path) .. ", "
                        .. groovy.quoted(task.shown .. NOT_RUN) .. "],"
  end
  lines[#lines + 1] = "]"
  lines[#lines + 1] = "gradle.taskGraph.whenReady { graph ->"
  lines[#lines + 1] = "  def build = gradle.parent == null ? '' : gradle.rootProject.name"
  lines[#lines + 1] = "  daukleCarried.findAll { it[0] == build && !graph.hasTask(it[1]) }.each { println it[2] }"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

return migrate_carry
