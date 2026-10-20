--- The jars a migration compares: which tasks of the old build make them,
--- where `build` copies each one, and where the new manifest's proof task
--- writes its counterpart.
local migrate_jars = {}

local migrate_paths = daukle.require("lib/migrate_paths")
local composite = daukle.require("lib/composite")

local within = migrate_paths.within
local derived = migrate_paths.derived

local OLD_JARS = "migrate-old"
local PLAN = "migrate-old-jars.tsv"
local COPY_TASK_PREFIX = "daukleMigrateOld"
local JAR_TASKS = { "jar", "sourcesJar" }
local ROOT_PATH = ":"

migrate_jars.PLAN = PLAN

local function task_named(project, name)
  for _, task in ipairs((project or {}).tasks or {}) do
    if task.name == name then return task end
  end
  return nil
end

--- The archive a task of the model writes, relative to its build's root
--- directory, or nil when the task is missing, disabled or unreadable.
local function archive_of(project, name)
  local task = task_named(project, name)
  if task == nil or task.enabled == false or type(task.values) ~= "table" then return nil end
  local file, directory = task.values.archiveFileName, task.values.destinationDirectory
  if type(file) ~= "string" or type(directory) ~= "string" then return nil end
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

--- Where the new build writes its counterpart of the old archive, relative
--- to the migration's directory; nil when it lies outside the build.
---
--- @implNote with no generated model the old archive's own place stands in:
--- the run is blocked then, and the proof is only there to be well formed.
local function new_archive(context, side, name, old)
  local archive = old
  if side.generated ~= nil then archive = archive_of(side.generated, name) end
  if archive == nil or not migrate_paths.is_below(archive.directory) then return nil end
  return derived(context, within(side.generated_root, archive.directory .. "/" .. archive.file))
end

--- One row per jar both sides make, its row number naming its own copy
--- directory so that no two jars of one file name meet and no copy task's
--- output holds another's.
local function add_rows(rows, context, side)
  for _, name in ipairs(JAR_TASKS) do
    local old = archive_of(side.project, name)
    local new = old ~= nil and new_archive(context, side, name, old) or nil
    if new ~= nil then
      local into = OLD_JARS .. "/" .. (#rows + 1)
      rows[#rows + 1] = { cli = task_path(side.identity, side.project.path, copy_task_of(name)),
                          dir = side.dir, task = name, into = migrate_paths.derived_from_instance(context, into),
                          included = side.identity ~= nil,
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
--- @return { { cli, dir, task, into, included, old, new } }, in the order the proof lists them;
---         `dir` and `into` relative to the instance's directory, where Gradle runs, `old` and
---         `new` to the directory migrate runs in
function migrate_jars.rows(context, built, generated, generated_builds)
  local rows = {}
  local generated_projects = generated_by_path(generated)
  for _, entry in ipairs(built.projects) do
    if entry.module ~= nil or built.declared == nil then
      add_rows(rows, context, { project = entry.project, dir = entry.project.dir, generated_root = nil,
                                generated = generated_projects[entry.project.path] })
    end
  end
  for _, record in ipairs(built.builds) do
    local counterpart = generated_builds[record.dir]
    add_rows(rows, context, { project = record.project, dir = within(record.dir, record.project.dir),
                              identity = record.identity, generated_root = composite.path_of(record.dir),
                              generated = counterpart ~= nil and counterpart.model.projects[1] or nil })
  end
  return rows
end

local function needs_more_than_main_jars(rows)
  for _, row in ipairs(rows) do
    if row.task ~= "jar" or row.included then return true end
  end
  return false
end

--- The proof core runs: the main jars alone are `<instance>:jar`'s, and a
--- sources jar or an included build's jar needs `<instance>:jars`.
function migrate_jars.proof(context, rows)
  if #rows == 0 then return nil end
  local compare = {}
  for _, row in ipairs(rows) do compare[#compare + 1] = { old = row.old, new = row.new, as = "archive" } end
  local task = needs_more_than_main_jars(rows) and "jars" or "jar"
  return { task = context.instance .. ":" .. task, compare = compare }
end

--- The plan `build` runs and the old build's init script reads, one
--- tab-separated row per line: the Gradle and JDK versions, then each jar.
function migrate_jars.plan_text(rows, gradle_version, jdk_version)
  local lines = { "gradle\t" .. (gradle_version or ""), "jdk\t" .. jdk_version }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = table.concat({ "jar", row.cli, row.dir, row.task, row.into }, "\t")
  end
  return table.concat(lines, "\n") .. "\n"
end

local function fields_of(line)
  local fields = {}
  for field in string.gmatch(line .. "\t", "([^\t]*)\t") do fields[#fields + 1] = field end
  return fields
end

--- The plan `run` wrote: { gradle = <version or nil>, jdk, tasks = <the copy tasks to run> }.
function migrate_jars.read_plan(context)
  local plan = { tasks = {} }
  for line in string.gmatch(daukle.read(derived(context, PLAN)), "[^\n]+") do
    local fields = fields_of(line)
    if fields[1] == "gradle" and fields[2] ~= "" then plan.gradle = fields[2] end
    if fields[1] == "jdk" then plan.jdk = fields[2] end
    if fields[1] == "jar" then plan.tasks[#plan.tasks + 1] = fields[2] end
  end
  return plan
end

return migrate_jars
