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

local function project_of_statements(statements)
  return project_with({}, { statements = statements })
end

local HELPER_CHAIN = {
  statement(1, 1, { definition = true, defines = { "inner" }, registers = { "made" } }),
  definition(2, 3, "outer", { "inner" }),
  statement(3, 5, { uses = { "outer" } }),
}

local USED_ONLY_BY_RULE_THREE = {
  statement(1, 1, { registers = { "greet" }, uses = { "helper" } }),
  definition(2, 3, "helper"),
  statement(3, 5, { uses = { "helper" } }),
}

local CALLER_EXTENDED_BY_RULE_THREE = {
  definition(1, 1, "tool"),
  statement(2, 3, { definition = true, defines = { "addMade" }, registers = { "made" } }),
  statement(3, 5, { uses = { "addMade", "tool" } }),
}

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
  { "two unheld actions of one task block once",
    function()
      return migrate_logic.select(project_with({ { sourceFile = "build.gradle", lastLine = 98 },
                                                 { sourceFile = "build.gradle", lastLine = 99 } }), {}, "root")
    end,
    "carried= blocked=greet" },
  { "rule 4 follows a chain of helpers",
    function() return migrate_logic.select(project_of_statements(HELPER_CHAIN), { "made" }, "root") end,
    "carried=1,2,3 blocked=" },
  { "a definition carried only by rule 3 does not pull its other callers",
    function() return migrate_logic.select(project_of_statements(USED_ONLY_BY_RULE_THREE), { "greet" }, "root") end,
    "carried=1,2 blocked=" },
  { "rule 3 extends what rule 4 carried",
    function() return migrate_logic.select(project_of_statements(CALLER_EXTENDED_BY_RULE_THREE), { "made" }, "root") end,
    "carried=1,2,3 blocked=" },
  { "a script that did not parse blocks with the reason",
    function() return migrate_logic.select(project_with({}, { unparsed = "unexpected token", statements = false }), {}, "root") end,
    "carried= blocked=unexpected token" },
  { "an action whose class file could not be read blocks by its task",
    function() return migrate_logic.select(project_with({ { script = "build.gradle" } }), {}, "root") end,
    "carried= blocked=greet" },
  { "a task action with no compiled script is ignored",
    function() return migrate_logic.select(project_with({ { type = "Foo" } }), {}, "root") end,
    "carried= blocked=" },
}

local PATHS = {
  { "brazier", ":tools:idea", "kotlin", "daukle/gradle/logic/brazier/tools/idea.gradle.kts" },
  { "root", ":", "groovy", "daukle/gradle/logic/root/root.gradle" },
  { "root", ":app", "groovy", "daukle/gradle/logic/root/app.gradle" },
}

local function covered_names(selection)
  local names = {}
  for name in pairs(selection.covered) do names[#names + 1] = name end
  table.sort(names)
  return table.concat(names, ",")
end

local COVERED = {
  { "a task whose action is carried is covered",
    function() return migrate_logic.select(project_with({ GREET_ACTION }), {}, "root") end, "greet" },
  { "a task with an action that was not found is not covered",
    function()
      return migrate_logic.select(project_with({ GREET_ACTION, { sourceFile = "build.gradle", lastLine = 99 } }), {}, "root")
    end, "" },
  { "a missing task a carried statement registers is covered",
    function() return migrate_logic.select(project_with({}), { "made" }, "root") end, "made" },
}

local TEXTS = {
  { "a Kotlin file takes its imports first, one blank line between statements",
    { { text = "val a = 1" }, { text = "import x.Y" } }, "kotlin", "import x.Y\n\nval a = 1\n" },
  { "a Groovy file keeps source order",
    { { text = "def a = 1" }, { text = "import x.Y" } }, "groovy", "def a = 1\n\nimport x.Y\n" },
  { "a CRLF statement keeps CRLF between statements",
    { { text = "tasks.register('a') {\r\n}" }, { text = "def b = 2" } }, "groovy",
    "tasks.register('a') {\r\n}\r\n\r\ndef b = 2\r\n" },
}

local function report_covered()
  local lines = {}
  for _, entry in ipairs(COVERED) do
    local actual = covered_names(entry[2]())
    lines[#lines + 1] = (actual == entry[3] and "ok " or "FAIL " .. actual .. " ") .. entry[1]
  end
  return lines
end

local function report_texts()
  local lines = {}
  for _, entry in ipairs(TEXTS) do
    local actual = migrate_logic.text(entry[2], entry[3])
    lines[#lines + 1] = (actual == entry[4] and "ok " or "FAIL " .. string.format("%q", actual) .. " ") .. entry[1]
  end
  return lines
end

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
    for _, line in ipairs(report_covered()) do lines[#lines + 1] = line end
    for _, line in ipairs(report_texts()) do lines[#lines + 1] = line end
    return daukle.write{ path = "results.txt", text = table.concat(lines, "\n") .. "\n" }
  end,
}
