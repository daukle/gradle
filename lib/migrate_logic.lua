--- Which top-level statements of a build script `daukle/gradle` carries
--- verbatim into a `verbatim` key, and that key's text. The init script
--- reports facts per statement and never selects; this selects and never parses.
local migrate_logic = {}

local migrate_surface = daukle.require("lib/migrate_surface")

local blocker = migrate_surface.blocker
local BOUNDARY_ROW = migrate_surface.BOUNDARY_ROW

local function normalized(path)
  return string.lower((string.gsub(path, "\\", "/")))
end

--- @implNote a class's `SourceFile` attribute is the bare file name unless the
--- file lies outside the build, while `script.path` is relative to it, so a
--- name without a separator is compared with the path's last segment. Case is
--- folded because Windows paths are case-insensitive. An applied script of the
--- same bare name never reaches this: its action is matched first by the full
--- path the dump reads from the class loader.
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

local function is_compiled_from(action, script_path)
  return action.sourceFile ~= nil and is_build_script(action.sourceFile, script_path)
end

--- The actions not compiled from the build's settings script, which the
--- settings selection carries instead (spec D-187, 4.1).
--- @param settings_path nil to keep every action
local function actions_outside(actions, settings_path)
  if settings_path == nil then return actions end
  local kept = {}
  for _, action in ipairs(actions) do
    if not is_compiled_from(action, settings_path) then kept[#kept + 1] = action end
  end
  return kept
end

--- Each task with only the actions compiled from `script_path`, for selecting
--- over a settings script whose hooks reach every project.
local function with_actions_from(tasks, script_path)
  local filtered = {}
  for _, task in ipairs(tasks) do
    local actions = {}
    for _, action in ipairs(task.actions or {}) do
      if is_compiled_from(action, script_path) then actions[#actions + 1] = action end
    end
    filtered[#filtered + 1] = { name = task.name, actions = actions }
  end
  return filtered
end

local function unreadable_class_blocker(action, where)
  return boundary_blocker(action.task, where, "has an action compiled from " .. action.script
    .. " whose class file could not be read, so no statement can be found to carry it")
end

local function unparsed_applied_blocker(inventory, where)
  return boundary_blocker(inventory.unparsed, where, "is why the applied script " .. inventory.path
    .. " cannot be read, so no statement of it is carried")
end

--- An applied script's statements, each keyed by its script as well as its
--- index so that it never meets a build script statement's key.
local function statements_of_applied(inventory)
  local statements = {}
  for _, statement in ipairs(inventory.statements or {}) do
    local copy = {}
    for key, value in pairs(statement) do copy[key] = value end
    copy.index = inventory.path .. "#" .. string.format("%d", statement.index)
    copy.script = inventory.path
    statements[#statements + 1] = copy
  end
  return statements
end

--- The scripts a project's statements come from: its build script, and each
--- script its build applied that the dump inventoried, in the dump's order
--- (spec D-188, 4.1 and 4.2).
local function sources_of(project, applied)
  local sources = { own = project.script or { path = "", statements = {} }, applied = {}, order = {} }
  for _, path in ipairs(project.appliedScripts or {}) do
    local inventory = (applied or {})[path]
    if inventory ~= nil then
      local key = normalized(path)
      sources.applied[key] = { inventory = inventory, statements = statements_of_applied(inventory) }
      sources.order[#sources.order + 1] = key
    end
  end
  return sources
end

local function applied_source_of(action, sources)
  if action.script == nil then return nil end
  return sources.applied[normalized(action.script)]
end

--- The script an action was compiled from, as { statements, path }, or the
--- blocker that says why none of its statements can be found.
local function script_of_action(action, sources, where)
  local applied = applied_source_of(action, sources)
  if applied ~= nil then
    if applied.inventory.unparsed ~= nil then
      return nil, applied.inventory.path, unparsed_applied_blocker(applied.inventory, where)
    end
    return { statements = applied.statements, path = applied.inventory.path }
  end
  if is_build_script(action.sourceFile, sources.own.path) then
    return { statements = sources.own.statements, path = sources.own.path }
  end
  return nil, action.sourceFile, boundary_blocker(action.sourceFile, where, "compiled an action of task "
    .. action.task .. " and is not the build script, so its text is not carried")
end

--- Rule 1: the statements holding a script-compiled action's last line, in
--- the build script or the applied script that compiled it, the blockers for
--- an action that no statement holds, and the tasks with such an action.
local function statements_with_actions(sources, tasks, where, settings_path)
  local seeds, blockers, reported, reported_tasks = {}, {}, {}, {}
  local located, unlocated = {}, {}
  local function report_task(action, found_blocker)
    unlocated[action.task] = true
    if not reported_tasks[action.task] then
      reported_tasks[action.task] = true
      blockers[#blockers + 1] = found_blocker
    end
  end
  for _, action in ipairs(actions_outside(script_actions({ tasks = tasks }), settings_path)) do
    if action.sourceFile == nil then
      report_task(action, unreadable_class_blocker(action, where))
    else
      local script, reported_script, script_blocker = script_of_action(action, sources, where)
      if script == nil then
        unlocated[action.task] = true
        if not reported[reported_script] then
          reported[reported_script] = true
          blockers[#blockers + 1] = script_blocker
        end
      else
        local statement = action.lastLine and statement_holding(script.statements, action.lastLine)
        if statement then
          seeds[#seeds + 1] = statement
          located[action.task] = located[action.task] or {}
          located[action.task][#located[action.task] + 1] = statement
        else
          report_task(action, boundary_blocker(action.task, where, "has an action compiled from "
            .. script.path .. " that no statement of it holds"))
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
--- hold an action of, unless another of its actions was not found or was
--- not carried, or it is missing and they do not register it.
---
--- @implNote a missing task left uncovered blocks through signal 1 or 2 by
--- name, in the words a build that carries nothing has always been given, and
--- so does a task whose statement a refused applied script held.
local function covered_tasks(registered, actions, carried, missing_task_names)
  local covered = {}
  for name in pairs(registered) do covered[name] = true end
  for name in pairs(actions.located) do covered[name] = true end
  for name in pairs(actions.unlocated) do covered[name] = nil end
  for name, statements in pairs(actions.located) do
    for _, statement in ipairs(statements) do
      if not carried[statement.index] then covered[name] = nil end
    end
  end
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

local function is_read_by(carried, catalog)
  for _, statement in ipairs(carried) do
    if includes(statement.uses, catalog) then return true end
  end
  return false
end

--- The version catalogs a carried statement reads, which the migration writes
--- and declares by a key, since the generated build declares none of its own.
local function catalogs_read(carried, catalogs)
  local read = {}
  for _, catalog in ipairs(catalogs or {}) do
    if is_read_by(carried, catalog) then read[#read + 1] = catalog end
  end
  return read
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

local function applied_key(statement, sources)
  if statement.applies == nil then return nil end
  local key = normalized(statement.applies)
  if sources.applied[key] == nil then return nil end
  return key
end

--- Every statement the rules may select: the build script's, less those that
--- apply a script whose own statements stand in for them (spec D-188, 4.4),
--- and every parsed applied script's.
local function selectable_statements(sources)
  local statements = {}
  for _, statement in ipairs(sources.own.statements or {}) do
    if applied_key(statement, sources) == nil then statements[#statements + 1] = statement end
  end
  for _, key in ipairs(sources.order) do append_all(statements, sources.applied[key].statements) end
  return statements
end

local function holds_carried(statements, carried)
  for _, statement in ipairs(statements) do
    if carried[statement.index] then return true end
  end
  return false
end

local function uncarry(statements, carried)
  for _, statement in ipairs(statements) do carried[statement.index] = nil end
end

local function applied_twice_blocker(path, where)
  return boundary_blocker(path, where, "is applied twice by the build script, and its carried statements"
    .. " would run once, so none of it is carried")
end

local function other_dsl_blocker(inventory, dsl, where)
  return boundary_blocker(inventory.path, where, "is a " .. inventory.dsl .. " script applied to a " .. dsl
    .. " build, and one verbatim key holds one DSL, so its statements are not carried")
end

local function buildscript_blocker(inventory, where)
  return boundary_blocker(inventory.path, where, "holds a buildscript block, whose classpath an applied"
    .. " script keeps to itself, so its statements are not carried")
end

local function holds_buildscript(statements)
  for _, statement in ipairs(statements) do
    if string.match(statement.text, "^buildscript%s*{") then return true end
  end
  return false
end

--- The DSL and line ending the carried text takes: the build script's, or,
--- for a project with none, the first applied script's that carries any.
local function carried_format(sources, carried)
  if sources.own.path ~= "" then return sources.own.dsl, sources.own.lineEnding end
  for _, key in ipairs(sources.order) do
    local applied = sources.applied[key]
    if holds_carried(applied.statements, carried) then return applied.inventory.dsl, applied.inventory.lineEnding end
  end
  return nil, nil
end

--- Drops what an applied script would carry where carrying it cannot be
--- right, with the blocker that names why (spec D-188, 4.6; section 3).
local function refuse_applied(sources, carried, where)
  local blockers, applications = {}, {}
  for _, statement in ipairs(sources.own.statements or {}) do
    local key = applied_key(statement, sources)
    if key ~= nil then applications[key] = (applications[key] or 0) + 1 end
  end
  local dsl = carried_format(sources, carried)
  for _, key in ipairs(sources.order) do
    local applied = sources.applied[key]
    if holds_carried(applied.statements, carried) then
      local refusal
      if (applications[key] or 0) > 1 then refusal = applied_twice_blocker(applied.inventory.path, where)
      elseif applied.inventory.dsl ~= dsl then refusal = other_dsl_blocker(applied.inventory, dsl, where)
      elseif holds_buildscript(applied.statements) then refusal = buildscript_blocker(applied.inventory, where) end
      if refusal ~= nil then
        blockers[#blockers + 1] = refusal
        uncarry(applied.statements, carried)
      end
    end
  end
  return blockers
end

--- The carried statements in the order the old build ran them: an applied
--- script's at the build script statement that applied it, and those of a
--- script applied from elsewhere, a parent's `subprojects {}` say, first
--- (spec D-188, 4.3).
local function in_build_order(sources, carried)
  local selected, placed = {}, {}
  for _, statement in ipairs(sources.own.statements or {}) do
    local key = applied_key(statement, sources)
    if key ~= nil then placed[key] = true end
  end
  for _, key in ipairs(sources.order) do
    if not placed[key] then append_all(selected, in_source_order(sources.applied[key].statements, carried)) end
  end
  for _, statement in ipairs(sources.own.statements or {}) do
    local key = applied_key(statement, sources)
    if key ~= nil then
      append_all(selected, in_source_order(sources.applied[key].statements, carried))
    elseif carried[statement.index] then
      selected[#selected + 1] = statement
    end
  end
  return selected
end

--- @param project a dumped project: its `script`, its `appliedScripts` and its tasks' `actions`
--- @param missing_task_names the tasks signal 2 found the generated build lacks
--- @param settings_path the build's settings script, whose actions this leaves to `select_settings`
--- @param applied the build's applied scripts as the dump inventoried them, by path
--- @param forced statements carried whatever the rules find, or nil
--- @return table { carried = statements in the order the old build ran them, blockers = blockers,
---         covered = set of the task names the carried statements account for,
---         catalogs = the names of the version catalogs a carried statement reads,
---         dsl, lineEnding = the format the carried text takes }
function migrate_logic.select(project, missing_task_names, where, settings_path, applied, forced)
  local script = project.script or { path = "", statements = {} }
  if script.unparsed ~= nil then return unparsed_result(project, missing_task_names, where) end
  local sources = sources_of(project, applied)
  local statements = selectable_statements(sources)
  local seeds, blockers, actions = statements_with_actions(sources, project.tasks, where, settings_path)
  append_all(seeds, statements_registering(statements, missing_task_names))
  append_all(seeds, forced or {})
  local carried = {}
  for _, seed in ipairs(seeds) do add(carried, seed) end
  local active = activate_definitions(seeds)
  repeat
    local changed = carry_used_definitions(statements, carried)
    changed = carry_callers(statements, active, carried) or changed
  until not changed
  append_all(blockers, refuse_applied(sources, carried, where))
  local registered = registered_by(statements, carried)
  local selected = in_build_order(sources, carried)
  local dsl, line_ending = carried_format(sources, carried)
  return { carried = selected, blockers = blockers, covered = covered_tasks(registered, actions, carried, missing_task_names),
           catalogs = catalogs_read(selected, project.catalogs), dsl = dsl, lineEnding = line_ending }
end

--- The rules of `select` over a parsed settings script, whose hooks reach
--- every project of its build (spec D-187, 4.1).
--- @param selectable the statements that may be carried: no declaration, which the render already writes
--- @param tasks every task of every project of the build
--- @param forced statements carried whatever the rules find, or nil
function migrate_logic.select_settings(script, selectable, tasks, missing_task_names, where, forced)
  local project = { script = { path = script.path, statements = selectable },
                    tasks = with_actions_from(tasks, script.path) }
  return migrate_logic.select(project, missing_task_names, where, nil, nil, forced)
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
