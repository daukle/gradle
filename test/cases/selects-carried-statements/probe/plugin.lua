daukle.plugin{ api = 1, uses = { "write" },
               requires = { gradle = { url = "https://invalid.example/plugin.lua", sha256 = "0000000000000000000000000000000000000000000000000000000000000000" } } }

local migrate_logic = daukle.require("gradle:lib/migrate_logic")

daukle.toolchain{ name = "probe", generate = function() return {} end }

local function statement(index, line, fields)
  fields.index, fields.startLine, fields.endLine = index, line, fields.endLine or line
  fields.text = "statement " .. index
  return fields
end

local function definition(index, line, name, uses, endLine)
  return statement(index, line, { definition = true, defines = { name }, uses = uses or {}, endLine = endLine })
end

local STATEMENTS = {
  definition(1, 1, "Util"),
  definition(2, 3, "base", { "Util" }),
  definition(3, 5, "prefix", { "base" }),
  statement(4, 7, { registers = { "greet" }, uses = { "prefix" }, endLine = 9 }),
  definition(5, 11, "unrelated"),
  statement(6, 13, { definition = true, defines = { "addMade" }, registers = { "made" }, endLine = 15 }),
  statement(7, 17, { uses = { "addMade" } }),
  statement(8, 19, { uses = { "println" } }),
}

local function project_with(actions, script_overrides)
  local script = { path = "build.gradle", dsl = "groovy", statements = STATEMENTS }
  for key, value in pairs(script_overrides or {}) do script[key] = value end
  return { script = script, tasks = { { name = "greet", actions = actions } } }
end

local function indices(selection)
  local found = {}
  for _, selected in ipairs(selection.carried) do found[#found + 1] = tostring(selected.index) end
  return table.concat(found, ",")
end

local function constructs(selection)
  local found = {}
  for _, blocker in ipairs(selection.blockers) do found[#found + 1] = blocker.construct end
  return table.concat(found, ",")
end

local function describe(selection)
  return "carried=" .. indices(selection) .. " blocked=" .. constructs(selection)
end

local GREET_ACTION = { sourceFile = "build.gradle", lastLine = 8 }

local CASES = {
  { "an action line carries its statement and, transitively, the definitions it uses (rules 1 and 3)",
    function() return migrate_logic.select(project_with({ GREET_ACTION }), {}, "root") end,
    "carried=1,2,3,4 blocked=" },
  { "a registered missing task carries its helper and the statement calling it (rules 2 and 4)",
    function() return migrate_logic.select(project_with({ GREET_ACTION }), { "made" }, "root") end,
    "carried=1,2,3,4,6,7 blocked=" },
  { "a missing task no statement registers blocks by name",
    function() return migrate_logic.select(project_with({}), { "ghost" }, "root") end,
    "carried= blocked=ghost" },
  { "an action compiled from another file blocks naming that file",
    function() return migrate_logic.select(project_with({ { sourceFile = "gradle/deps.gradle", lastLine = 3 } }), {}, "root") end,
    "carried= blocked=gradle/deps.gradle" },
  { "a bare source file name matches the script's last segment whatever its case",
    function()
      return migrate_logic.select(project_with({ { sourceFile = "BUILD.Gradle", lastLine = 8 } }, { path = "sub\\build.gradle" }), {}, "root")
    end,
    "carried=1,2,3,4 blocked=" },
  { "an action whose line no statement holds blocks by its task",
    function() return migrate_logic.select(project_with({ { sourceFile = "build.gradle", lastLine = 99 } }), {}, "root") end,
    "carried= blocked=greet" },
  { "a script that did not parse blocks with the reason",
    function() return migrate_logic.select(project_with({}, { unparsed = "unexpected token", statements = false }), {}, "root") end,
    "carried= blocked=unexpected token" },
  { "a task action with no compiled script is ignored",
    function() return migrate_logic.select(project_with({ { type = "Foo" } }), {}, "root") end,
    "carried= blocked=" },
}

local PATHS = {
  { "brazier", ":tools:idea", "kotlin", "daukle/gradle/logic/brazier/tools/idea.gradle.kts" },
  { "root", ":", "groovy", "daukle/gradle/logic/root/root.gradle" },
  { "root", ":app", "groovy", "daukle/gradle/logic/root/app.gradle" },
}

local function report_selections()
  local lines = {}
  for _, entry in ipairs(CASES) do
    local actual = describe(entry[2]())
    lines[#lines + 1] = (actual == entry[3] and "ok " or "FAIL " .. actual .. " ") .. entry[1]
  end
  return lines
end

local function report_paths()
  local lines = {}
  for _, entry in ipairs(PATHS) do
    local actual = migrate_logic.file_path(entry[1], entry[2], entry[3])
    lines[#lines + 1] = (actual == entry[4] and "ok " or "FAIL " .. actual .. " ") .. entry[4]
  end
  return lines
end

daukle.task{
  name = "probe:report",
  run = function()
    local lines = report_selections()
    for _, line in ipairs(report_paths()) do lines[#lines + 1] = line end
    return daukle.write{ path = "results.txt", text = table.concat(lines, "\n") .. "\n" }
  end,
}
