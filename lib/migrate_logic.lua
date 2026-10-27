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
function migrate_logic.file_path(build, project_path, dsl)
  local project = ROOT
  if project_path ~= ":" then
    project = string.gsub(string.sub(project_path, 2), ":", "/")
  end
  return "daukle/gradle/logic/" .. build .. "/" .. project .. EXTENSIONS[dsl]
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

local function script_actions(project)
  local actions = {}
  for _, task in ipairs(project.tasks or {}) do
    for _, action in ipairs(task.actions or {}) do
      if action.sourceFile ~= nil then
        actions[#actions + 1] = { task = task.name, sourceFile = action.sourceFile, lastLine = action.lastLine }
      end
    end
  end
  return actions
end

--- Rule 1: the statements holding a script-compiled action's last line, and
--- the blockers for an action that no statement of the build script holds.
local function statements_with_actions(script, tasks, where)
  local seeds, blockers, reported, reported_tasks = {}, {}, {}, {}
  for _, action in ipairs(script_actions({ tasks = tasks })) do
    if not is_build_script(action.sourceFile, script.path) then
      if not reported[action.sourceFile] then
        reported[action.sourceFile] = true
        blockers[#blockers + 1] = boundary_blocker(action.sourceFile, where, "compiled an action of task "
          .. action.task .. " and is not the build script, so its text is not carried")
      end
    else
      local statement = action.lastLine and statement_holding(script.statements, action.lastLine)
      if statement then
        seeds[#seeds + 1] = statement
      elseif not reported_tasks[action.task] then
        reported_tasks[action.task] = true
        blockers[#blockers + 1] = boundary_blocker(action.task, where, "has an action compiled from "
          .. script.path .. " that no statement of it holds")
      end
    end
  end
  return seeds, blockers
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

local function unregistered_blockers(statements, missing_task_names, carried, where)
  local registered = {}
  for _, statement in ipairs(statements) do
    if carried[statement.index] then
      for _, name in ipairs(statement.registers or {}) do registered[name] = true end
    end
  end
  local blockers = {}
  for _, name in ipairs(missing_task_names) do
    if not registered[name] then
      blockers[#blockers + 1] = boundary_blocker(name, where, "is a task the old build has and no statement of"
        .. " its build script registers, so nothing can be carried to create it")
    end
  end
  return blockers
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

local function unparsed_result(script, where)
  return { carried = {}, blockers = {
    boundary_blocker(script.unparsed, where, "is why the build script " .. script.path
      .. " cannot be read, so no statement of it is carried"),
  } }
end

--- @param project a dumped project: its `script` and its tasks' `actions`
--- @param missing_task_names the tasks signal 2 found the generated build lacks
--- @return table { carried = statements in source order, blockers = blockers }
function migrate_logic.select(project, missing_task_names, where)
  local script = project.script or { path = "", statements = {} }
  if script.unparsed ~= nil then return unparsed_result(script, where) end
  local statements = script.statements
  local seeds, blockers = statements_with_actions(script, project.tasks, where)
  append_all(seeds, statements_registering(statements, missing_task_names))
  local carried = {}
  for _, seed in ipairs(seeds) do add(carried, seed) end
  local active = activate_definitions(seeds)
  repeat
    local changed = carry_used_definitions(statements, carried)
    changed = carry_callers(statements, active, carried) or changed
  until not changed
  append_all(blockers, unregistered_blockers(statements, missing_task_names, carried, where))
  return { carried = in_source_order(statements, carried), blockers = blockers }
end

return migrate_logic
