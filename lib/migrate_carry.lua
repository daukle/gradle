--- What a migration carries of the old build's code: per project and included
--- build, the statements lib/migrate_logic selects, set as that project's
--- `verbatim` key, and the tasks they account for, which signal 1 no longer
--- blocks (spec D-165, sections 4.1, 4.3, 4.5; spec D-198, 4.3).
local migrate_carry = {}

local migrate_logic = daukle.require("lib/migrate_logic")
local migrate_catalogs = daukle.require("lib/migrate_catalogs")
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

--- Every project a `verbatim` key can be set for, with what places it: the main
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

local function duplicate_blocker(target, label)
  return boundary_blocker(label, target.where, "would hold the build logic of two projects, " .. target.label
                          .. " among them, so neither is carried")
end

local function new_result()
  return { covered = {}, tasks = {}, statements = {}, blockers = {} }
end

local function is_placed(place)
  return place.build ~= nil or place.module ~= nil or place.root == true
end

--- The `verbatim` key a place sets, as the warn line and the blockers name it.
local function label_of(place)
  if place.build ~= nil then return "builds." .. place.build .. ".verbatim" end
  if place.module ~= nil then return "modules." .. place.module .. ".verbatim" end
  return "verbatim"
end

local function catalogs_block(config, place)
  if place.build ~= nil then return config.builds[place.build] end
  return config
end

local function missing_catalog_blocker(target, name)
  return boundary_blocker(name, target.where, "is a version catalog that carried code reads, and the dump"
                          .. " holds no contents for it, so it cannot be written")
end

--- Declares each catalog the carried code reads, once per build, by the
--- `catalogs` key of the build the code is carried into.
---
--- @param dumped the build's catalogs as the dump read them, by name
local function carry_catalogs(target, names, dumped, config, result)
  local block = catalogs_block(config, target.place)
  for _, name in ipairs(names) do
    local catalog = (dumped or {})[name]
    if catalog == nil then
      result.blockers[#result.blockers + 1] = missing_catalog_blocker(target, name)
    elseif (block.catalogs or {})[name] == nil then
      local declared = migrate_catalogs.table_of(name, catalog, target.where)
      append(result.blockers, declared.blockers)
      block.catalogs = block.catalogs or {}
      block.catalogs[name] = declared.catalog
    end
  end
end

local function task_types(project)
  local types = {}
  for _, task in ipairs(project.tasks or {}) do types[task.name] = task.type end
  return types
end

local function holds_an_action_of(statement, task)
  for _, action in ipairs(task.actions or {}) do
    local line = action.lastLine
    if line ~= nil and statement.startLine <= line and line <= statement.endLine then return true end
  end
  return false
end

--- The `GRADLE-SURFACE.md` row a carried statement is coverage owed against:
--- that of the first task it registers, else of the first whose action it
--- holds, else the boundary's, as for a definition or a helper.
local function row_of(statement, project)
  local types = task_types(project)
  for _, name in ipairs(statement.registers or {}) do
    return migrate_surface.row_of_task_type(types[name])
  end
  for _, task in ipairs(project.tasks or {}) do
    if holds_an_action_of(statement, task) then return migrate_surface.row_of_task_type(task.type) end
  end
  return migrate_surface.BOUNDARY_ROW
end

local function record_statements(result, carried_statements, label, project)
  for _, statement in ipairs(carried_statements) do
    result.statements[#result.statements + 1] = { label = label, line = statement.startLine,
                                                  row = row_of(statement, project) }
  end
end

local function carry_target(target, built, result, taken)
  local config = built.config
  local missing = target.counterpart ~= nil
                  and migrate_blockers.missing_task_names(target.project, target.counterpart) or {}
  local selection = migrate_logic.select(target.project, missing, target.where)
  append(result.blockers, selection.blockers)
  if #selection.carried == 0 then return end
  local dsl = dsl_of(target.project)
  if not is_placed(target.place) then
    result.blockers[#result.blockers + 1] = no_place_blocker(target)
    return
  end
  local label = label_of(target.place)
  if taken[label] then
    result.blockers[#result.blockers + 1] = duplicate_blocker(target, label)
    return
  end
  taken[label] = true
  translate_build.set_verbatim(config, target.place, dsl,
                               migrate_logic.text(selection.carried, dsl, (target.project.script or {}).lineEnding))
  record_statements(result, selection.carried, label .. "." .. dsl, target.project)
  carry_catalogs(target, selection.catalogs or {}, (built.catalogs or {})[target.build], config, result)
  result.covered[target.project] = selection.covered
  append(result.tasks, carried_task_paths(target, selection.covered))
end

--- Selects what every project carries, setting its `verbatim` and `catalogs`
--- keys in `built.config`.
---
--- @param built            what `translate_build.build` returned, with `catalogs`: each build's dumped
---                         catalogs, by "root" or the included build's directory
--- @param generated        the generated root build's model, rendered without carried code
--- @param generated_models the generated included builds' models, by directory
--- @return { covered = project -> set of task names, tasks = { { build, path, shown } },
---           statements = { { label, line, row } }, blockers }
function migrate_carry.select(built, generated, generated_models)
  local result, taken = new_result(), {}
  for _, target in ipairs(targets(built, generated, generated_models)) do
    carry_target(target, built, result, taken)
  end
  return result
end

local function derived_root_of(context, place)
  local root = carried.derived_of(context.instance)
  if place.build ~= nil then return root .. "/" .. composite.path_of(place.build) end
  return root
end

--- Each derived root an earlier carrying render linked to the real tree, as
--- the place whose `verbatim` key renders it carrying, and its derived root.
---
--- @implNote a render without carried code would write through those links into the
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

--- What a baseline `verbatim` holds: `verbatim.checked` refuses an empty
--- text, and the baseline renders it blank anyway.
migrate_carry.BASELINE_TEXT = "// the keys-only baseline\n"

--- The config the first render reads: the translation's, with a `verbatim`
--- wherever a derived root is linked, rendered blank, so nothing is written
--- through a link and the task set is the one the keys alone give.
function migrate_carry.baseline_config(config, linked)
  local copy = {}
  for key, value in pairs(config) do copy[key] = value end
  if config.builds ~= nil then
    copy.builds = {}
    for name, block in pairs(config.builds) do
      copy.builds[name] = {}
      for key, value in pairs(block) do copy.builds[name][key] = value end
    end
  end
  for _, entry in ipairs(linked) do
    translate_build.set_verbatim(copy, entry.place, GROOVY, migrate_carry.BASELINE_TEXT)
  end
  return copy
end

local function carries_at(config, place)
  if place.build ~= nil then return carried.included_build_carries((config.builds or {})[place.build] or {}) end
  return carried.build_carries(config)
end

--- A linked derived root the final config renders without carried code: the proof
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

--- One report line per carried statement, which the migration prints once.
local function statement_line(statement)
  return statement.label .. ": line " .. string.format("%d", statement.line) .. " carried verbatim, coverage owed ("
         .. statement.row .. ")"
end

--- The report script's text, which names each carried task the proof's task
--- graph does not hold and each carried statement; empty when nothing is carried.
---
--- @implNote decided by the graph the proof itself schedules, in each build
--- of the composite, rather than guessed from task types: carried code can
--- make a jar depend on anything. The statements print from the main build
--- alone, since every build of the composite runs this script.
function migrate_carry.report_script(tasks, statements)
  if #tasks == 0 and #statements == 0 then return "" end
  local lines = { "// Generated by daukle/gradle for the proof of a migration. Do not edit.",
                  "def daukleCarried = [" }
  for _, task in ipairs(tasks) do
    lines[#lines + 1] = "  [" .. groovy.quoted(task.build) .. ", " .. groovy.quoted(task.path) .. ", "
                        .. groovy.quoted(task.shown .. NOT_RUN) .. "],"
  end
  lines[#lines + 1] = "]"
  lines[#lines + 1] = "def daukleStatements = ["
  for _, statement in ipairs(statements) do
    lines[#lines + 1] = "  " .. groovy.quoted(statement_line(statement)) .. ","
  end
  lines[#lines + 1] = "]"
  lines[#lines + 1] = "gradle.taskGraph.whenReady { graph ->"
  lines[#lines + 1] = "  def build = gradle.parent == null ? '' : gradle.rootProject.name"
  lines[#lines + 1] = "  daukleCarried.findAll { it[0] == build && !graph.hasTask(it[1]) }.each { println it[2] }"
  lines[#lines + 1] = "  if (gradle.parent == null) daukleStatements.each { println it }"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

return migrate_carry
