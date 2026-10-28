--- The jars a migration compares: which tasks of the old build make them,
--- where `build` copies each one, and where the new manifest's proof task
--- writes its counterpart.
local migrate_jars = {}

local migrate_paths = daukle.require("lib/migrate_paths")
local migrate_surface = daukle.require("lib/migrate_surface")
local composite = daukle.require("lib/composite")
local model_dump = daukle.require("lib/model_dump")
local tables = daukle.require("lib/tables")
local carried = daukle.require("lib/carried")

local within = migrate_paths.within
local derived = migrate_paths.derived

local OLD_JARS = carried.MIGRATE_PREFIX .. "old"
local PLAN = carried.MIGRATE_PREFIX .. "old-jars.tsv"
local COPY_TASK_PREFIX = "daukleMigrateOld"
local JAR_READER = "jar"
local JAR_ROW = "jar"
local ROOT_PATH = ":"

--- The fields of a jar row of the plan, in the order they are written.
local PLAN_FIELDS = { "kind", "cli", "dir", "task", "into" }

migrate_jars.PLAN = PLAN
migrate_jars.COPY_TASK_PREFIX = COPY_TASK_PREFIX
migrate_jars.JAR_ROW = JAR_ROW

--- Each field of a jar row by name, as its column number in the plan.
migrate_jars.PLAN_COLUMNS = {}
for index, name in ipairs(PLAN_FIELDS) do migrate_jars.PLAN_COLUMNS[name] = index end

local function task_named(project, name)
  return tables.named((project or {}).tasks, name)
end

--- The archive an enabled task of the model writes, relative to its
--- build's root directory: { file, directory }, else nil and why it cannot
--- be named; nil and no reason when the task is missing or disabled, so it
--- writes no archive.
local function archive_of(project, name)
  local task = task_named(project, name)
  if task == nil or task.enabled == false then return nil end
  if task.enabled ~= true then return nil, "whether " .. name .. " is enabled could not be read" end
  if type(task.values) ~= "table" then return nil, name .. "'s values could not be read" end
  local file, directory = task.values.archiveFileName, task.values.destinationDirectory
  if type(file) ~= "string" then return nil, name .. ".archiveFileName could not be read" end
  if type(directory) ~= "string" then return nil, name .. ".destinationDirectory could not be read" end
  if model_dump.holds_environment(file) or model_dump.holds_environment(directory) then
    return nil, name .. " names its archive with the value of an environment variable"
  end
  return { file = file, directory = directory }
end

local function copy_task_of(name)
  return COPY_TASK_PREFIX .. string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

local function task_path(build_identity, project_path, name)
  local prefix = build_identity or ""
  if project_path ~= ROOT_PATH then prefix = prefix .. project_path end
  return prefix .. ":" .. name
end

local GENERATED = "the generated build's "

--- Where the new build writes its counterpart of the old archive, relative
--- to the migration's directory, else nil and why it cannot be named.
---
--- @implNote with no generated model the old archive's own place stands in:
--- the run is blocked then, and the proof is only there to be well formed.
--- A counterpart task the generated build lacks is not a reason here,
--- because the task-set comparison already blocks it.
local function new_archive(context, side, name, old)
  local archive = old
  if side.generated ~= nil then
    local task = task_named(side.generated, name)
    if task == nil then return nil, nil end
    if task.enabled == false then return nil, GENERATED .. name .. " is disabled" end
    local why
    archive, why = archive_of(side.generated, name)
    if archive == nil then return nil, GENERATED .. why end
  end
  if not migrate_paths.is_below(archive.directory) then
    return nil, GENERATED .. name .. " writes to " .. archive.directory .. ", outside its build"
  end
  return derived(context, within(side.generated_root, archive.directory .. "/" .. archive.file))
end

local function unnamed(side, name, why)
  return migrate_surface.blocker(name, side.where, "the proof cannot name its jar: " .. why,
                                 migrate_surface.UNCOVERED_ROW)
end

--- The old project's tasks of the `Jar` type: `jar`, `sourcesJar`, and any
--- a plugin registers, such as a fat jar.
local function jar_tasks(project)
  local names = {}
  for _, task in ipairs(project.tasks or {}) do
    if task.reader == JAR_READER then names[#names + 1] = task.name end
  end
  return names
end

--- One row per jar both sides make, its row number naming its own copy
--- directory so that no two jars of one file name meet and no copy task's
--- output holds another's; a jar the old build makes and the proof cannot
--- name is a blocker, never a jar left out of the comparison.
local function add_rows(rows, blockers, context, side)
  for _, name in ipairs(jar_tasks(side.project)) do
    local old, old_why = archive_of(side.project, name)
    local new, new_why = nil, nil
    if old ~= nil then new, new_why = new_archive(context, side, name, old) end
    local why = old_why or new_why
    if why ~= nil then
      blockers[#blockers + 1] = unnamed(side, name, why)
    elseif new ~= nil then
      local into = OLD_JARS .. "/" .. (#rows + 1)
      rows[#rows + 1] = { cli = task_path(side.identity, side.project.path, copy_task_of(name)),
                          dir = side.dir, task = name, into = migrate_paths.derived_from_instance(context, into),
                          old = derived(context, into .. "/" .. old.file), new = new }
    end
  end
end

local function generated_by_path(generated)
  local projects = {}
  for _, project in ipairs((generated or {}).projects or {}) do projects[project.path] = project end
  return projects
end

--- @param built            what `translate_build.build` returned
--- @param generated        the generated root build's model, or nil when it did not configure
--- @param generated_builds the generated included builds' models, by directory, each { identity, model }
--- @return { { cli, dir, task, into, old, new } }, in the order the proof lists them, `dir` and
---         `into` relative to the instance's directory, where Gradle runs, `old` and `new` to the
---         directory migrate runs in; and the blockers for the jars the proof cannot name
function migrate_jars.rows(context, built, generated, generated_builds)
  local rows, blockers = {}, {}
  local generated_projects = generated_by_path(generated)
  for _, entry in ipairs(built.projects) do
    if entry.module ~= nil or built.declared == nil then
      add_rows(rows, blockers, context, { project = entry.project, dir = entry.project.dir, where = entry.where,
                                          generated = generated_projects[entry.project.path] })
    end
  end
  for _, record in ipairs(built.builds) do
    local counterpart = generated_builds[record.dir]
    add_rows(rows, blockers, context, { project = record.project, dir = within(record.dir, record.project.dir),
                                        where = record.where, identity = record.identity,
                                        generated_root = composite.path_of(record.dir),
                                        generated = counterpart ~= nil and counterpart.model.projects[1] or nil })
  end
  return rows, blockers
end

--- The proof core runs: `<instance>:jars`, which builds every jar task of
--- every project and included build.
function migrate_jars.proof(context, rows)
  if #rows == 0 then return nil end
  local compare = {}
  for _, row in ipairs(rows) do compare[#compare + 1] = { old = row.old, new = row.new, as = "archive" } end
  return { task = context.instance .. ":jars", compare = compare }
end

local TAB = "\t"

local function jar_line(row)
  local fields = {}
  for index, name in ipairs(PLAN_FIELDS) do
    fields[index] = name == "kind" and JAR_ROW or row[name]
  end
  return table.concat(fields, TAB)
end

--- The plan `build` runs and the old build's init script reads, one
--- tab-separated row per line: the Gradle and JDK versions, then each jar.
function migrate_jars.plan_text(rows, gradle_version, jdk_version)
  local lines = { "gradle" .. TAB .. (gradle_version or ""), "jdk" .. TAB .. jdk_version }
  for _, row in ipairs(rows) do lines[#lines + 1] = jar_line(row) end
  return table.concat(lines, "\n") .. "\n"
end

local function fields_of(line)
  local fields = {}
  for field in string.gmatch(line .. TAB, "([^\t]*)\t") do fields[#fields + 1] = field end
  return fields
end

--- The plan `run` wrote: { gradle = <version or nil>, jdk, tasks = <the copy tasks to run> }.
function migrate_jars.read_plan(context)
  local plan = { tasks = {} }
  for line in string.gmatch(daukle.read(derived(context, PLAN)), "[^\n]+") do
    local fields = fields_of(line)
    if fields[1] == "gradle" and fields[2] ~= "" then plan.gradle = fields[2] end
    if fields[1] == "jdk" then plan.jdk = fields[2] end
    if fields[1] == JAR_ROW then plan.tasks[#plan.tasks + 1] = fields[migrate_jars.PLAN_COLUMNS.cli] end
  end
  return plan
end

return migrate_jars
