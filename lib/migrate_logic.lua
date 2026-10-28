--- Which top-level statements of a build script `daukle/gradle` carries
--- verbatim into a logic file, and where that file lives. The init script
--- reports facts per statement and never selects; this selects and never parses.
local migrate_logic = {}

local migrate_surface = daukle.require("lib/migrate_surface")

local blocker = migrate_surface.blocker
local BOUNDARY_ROW = migrate_surface.BOUNDARY_ROW

local EXTENSIONS = { groovy = ".gradle", kotlin = ".gradle.kts" }
local ROOT = "root"

--- @param build "root" or the included build's directory name
--- @param project_path ":" for a build's root project, else ":a:b"
--- @param instance the toolchain instance, whose `daukle/<instance>/` holds the file
function migrate_logic.file_path(build, project_path, dsl, instance)
  local project = ROOT
  if project_path ~= ":" then
    project = string.gsub(string.sub(project_path, 2), ":", "/")
  end
  return "daukle/" .. instance .. "/logic/" .. build .. "/" .. project .. EXTENSIONS[dsl]
end

local function normalized(path)
  return string.lower((string.gsub(path, "\\", "/")))
end

--- @implNote a class's `SourceFile` attribute is the bare file name unless the
--- file lies outside the build, while `script.path` is relative to it, so a
--- name without a separator is compared with the path's last segment. Case is
--- folded because Windows paths are case-insensitive. A bare name can collide
--- only with an applied or settings script of the same name, and such a build
--- is blocked by its apply-from blocker.
local function is_build_script(source_file, script_path)
  local wanted, actual = normalized(source_file), normalized(script_path)
  if wanted == actual then return true end
  if string.find(wanted, "/", 1, true) then return false end
  return wanted == string.match(actual, "([^/]*)$")
end

local function statement_holding(statements, line)
  for _, statement in ipairs(statements) do
    if statement.startLine <= line and line <= statement.endLine then return statement end
  end
  return nil
end

local function includes(list, wanted)
  for _, name in ipairs(list or {}) do
    if name == wanted then return true end
  end
  return false
end

local function boundary_blocker(construct, where, why)
  return blocker(construct, where, why, BOUNDARY_ROW)
end

local function is_script_compiled(action)
  return action.script ~= nil or action.sourceFile ~= nil
end

local function script_actions(project)
  local actions = {}
  for _, task in ipairs(project.tasks or {}) do
    for _, action in ipairs(task.actions or {}) do
      if is_script_compiled(action) then
        actions[#actions + 1] = { task = task.name, script = action.script, sourceFile = action.sourceFile,
                                  lastLine = action.lastLine }
      end
    end
  end
  return actions
end

local function unreadable_class_blocker(action, where)
  return boundary_blocker(action.task, where, "has an action compiled from " .. action.script
    .. " whose class file could not be read, so no statement can be found to carry it")
end

--- Rule 1: the statements holding a script-compiled action's last line, the
--- blockers for an action that no statement of the build script holds, and
--- the tasks with such an action.
local function statements_with_actions(script, tasks, where)
  local seeds, blockers, reported, reported_tasks = {}, {}, {}, {}
  local located, unlocated = {}, {}
  for _, action in ipairs(script_actions({ tasks = tasks })) do
    if action.sourceFile == nil then
      unlocated[action.task] = true
      if not reported_tasks[action.task] then
        reported_tasks[action.task] = true
        blockers[#blockers + 1] = unreadable_class_blocker(action, where)
      end
    elseif not is_build_script(action.sourceFile, script.path) then
      unlocated[action.task] = true
      if not reported[action.sourceFile] then
        reported[action.sourceFile] = true
        blockers[#blockers + 1] = boundary_blocker(action.sourceFile, where, "compiled an action of task "
          .. action.task .. " and is not the build script, so its text is not carried")
      end
    else
      local statement = action.lastLine and statement_holding(script.statements, action.lastLine)
      if statement then
        seeds[#seeds + 1] = statement
        located[action.task] = true
      else
        unlocated[action.task] = true
        if not reported_tasks[action.task] then
          reported_tasks[action.task] = true
          blockers[#blockers + 1] = boundary_blocker(action.task, where, "has an action compiled from "
            .. script.path .. " that no statement of it holds")
        end
      end
    end
  end
  return seeds, blockers, { located = located, unlocated = unlocated }
end

--- Rule 2: the statements registering a task the generated build lacks.
local function statements_registering(statements, missing_task_names)
  local seeds = {}
  for _, statement in ipairs(statements) do
    for _, name in ipairs(missing_task_names) do
      if includes(statement.registers, name) then
        seeds[#seeds + 1] = statement
        break
      end
    end
  end
  return seeds
end

local function registered_by(statements, carried)
  local registered = {}
  for _, statement in ipairs(statements) do
    if carried[statement.index] then
      for _, name in ipairs(statement.registers or {}) do registered[name] = true end
    end
  end
  return registered
end

--- The tasks the carried statements account for: each one they register or
--- hold an action of, unless another of its actions was not found or it is
--- missing and they do not register it.
---
--- @implNote a missing task left uncovered blocks through signal 1 or 2 by
--- name, in the words a build that carries nothing has always been given.
local function covered_tasks(registered, actions, missing_task_names)
  local covered = {}
  for name in pairs(registered) do covered[name] = true end
  for name in pairs(actions.located) do covered[name] = true end
  for name in pairs(actions.unlocated) do covered[name] = nil end
  for _, name in ipairs(missing_task_names) do
    if not registered[name] then covered[name] = nil end
  end
  return covered
end

local function add(carried, statement)
  if carried[statement.index] then return false end
  carried[statement.index] = true
  return true
end

local function is_used_by(definition, statement)
  for _, name in ipairs(definition.defines or {}) do
    if includes(statement.uses, name) then return true end
  end
  return false
end

--- Rule 3: definitions a carried statement uses.
local function carry_used_definitions(statements, carried)
  local changed = false
  for _, user in ipairs(statements) do
    if carried[user.index] then
      for _, definition in ipairs(statements) do
        if definition.definition and definition ~= user and is_used_by(definition, user) then
          changed = add(carried, definition) or changed
        end
      end
    end
  end
  return changed
end

local function activate_definitions(statements)
  local active = {}
  for _, statement in ipairs(statements) do
    if statement.definition then active[statement.index] = statement end
  end
  return active
end

--- Rule 4: statements calling a definition that rule 1 or 2 landed in, and
--- so on along the chain: a caller that is itself a definition is called in
--- turn. A definition carried only by rule 3 never enters `active`.
local function carry_callers(statements, active, carried)
  local changed, activated = false, {}
  for _, definition in ipairs(statements) do
    if active[definition.index] then
      for _, caller in ipairs(statements) do
        if caller ~= definition and is_used_by(definition, caller) then
          changed = add(carried, caller) or changed
          if caller.definition and not active[caller.index] then activated[caller.index] = true end
        end
      end
    end
  end
  for index in pairs(activated) do
    active[index] = true
    changed = true
  end
  return changed
end

local function in_source_order(statements, carried)
  local selected = {}
  for _, statement in ipairs(statements) do
    if carried[statement.index] then selected[#selected + 1] = statement end
  end
  return selected
end

local function append_all(target, items)
  for _, item in ipairs(items) do target[#target + 1] = item end
end

--- Carried statements that read a version catalog: the generated build links
--- the real `gradle/` directory but declares no catalog of its own, so a
--- catalog accessor in carried code would depend on that link and not on a key.
local function catalog_blockers(carried, catalogs, where)
  local blockers = {}
  for _, catalog in ipairs(catalogs or {}) do
    for _, statement in ipairs(carried) do
      if includes(statement.uses, catalog) then
        blockers[#blockers + 1] = boundary_blocker(catalog, where, "is a version catalog that carried code reads"
          .. " (first at line " .. string.format("%d", statement.startLine) .. "), and a version catalog is not"
          .. " carried: no key declares it")
        break
      end
    end
  end
  return blockers
end

local function needs_carrying(project, missing_task_names)
  return #missing_task_names > 0 or #script_actions(project) > 0
end

local function unparsed_result(project, missing_task_names, where)
  local script = project.script
  if not needs_carrying(project, missing_task_names) then return { carried = {}, covered = {}, blockers = {} } end
  return { carried = {}, covered = {}, blockers = {
    boundary_blocker(script.unparsed, where, "is why the build script " .. script.path
      .. " cannot be read, so no statement of it is carried"),
  } }
end

--- @param project a dumped project: its `script` and its tasks' `actions`
--- @param missing_task_names the tasks signal 2 found the generated build lacks
--- @return table { carried = statements in source order, blockers = blockers,
---         covered = set of the task names the carried statements account for,
---         reads_catalog = whether a carried statement reads a version catalog }
function migrate_logic.select(project, missing_task_names, where)
  local script = project.script or { path = "", statements = {} }
  if script.unparsed ~= nil then return unparsed_result(project, missing_task_names, where) end
  local statements = script.statements
  local seeds, blockers, actions = statements_with_actions(script, project.tasks, where)
  append_all(seeds, statements_registering(statements, missing_task_names))
  local carried = {}
  for _, seed in ipairs(seeds) do add(carried, seed) end
  local active = activate_definitions(seeds)
  repeat
    local changed = carry_used_definitions(statements, carried)
    changed = carry_callers(statements, active, carried) or changed
  until not changed
  local registered = registered_by(statements, carried)
  local selected = in_source_order(statements, carried)
  local catalog = catalog_blockers(selected, project.catalogs, where)
  append_all(blockers, catalog)
  return { carried = selected, blockers = blockers, covered = covered_tasks(registered, actions, missing_task_names),
           reads_catalog = #catalog > 0 }
end

local function is_import(statement)
  return string.match(statement.text, "^import%s") ~= nil
end

--- @implNote Kotlin takes an import only ahead of every other statement, and
--- the wrapper lifts the file's leading imports above its own blocks (spec 7.2).
local function in_file_order(statements, dsl)
  if dsl ~= "kotlin" then return statements end
  local imports, rest = {}, {}
  for _, statement in ipairs(statements) do
    if is_import(statement) then imports[#imports + 1] = statement else rest[#rest + 1] = statement end
  end
  append_all(imports, rest)
  return imports
end

--- The carried file: each statement's text verbatim, one blank line between.
---
--- @implNote the blank line takes the script's own line ending, so a CRLF
--- script does not gain LF lines between its own, even when every carried
--- statement is a single line.
--- @param line_ending the script's `lineEnding` from the dump, "crlf" or "lf"
function migrate_logic.text(statements, dsl, line_ending)
  local texts, line_end = {}, line_ending == "crlf" and "\r\n" or "\n"
  for _, statement in ipairs(in_file_order(statements, dsl)) do texts[#texts + 1] = statement.text end
  return table.concat(texts, line_end .. line_end) .. line_end
end

return migrate_logic
