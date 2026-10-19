local model_dump = daukle.require("lib/model_dump")
local launcher = daukle.require("lib/launcher")
local translate_model = daukle.require("lib/translate_model")

local INIT_SCRIPT = "migrate-model.gradle"
local MODEL = "migrate-model.json"
local PROJECT_CACHE = "migrate-cache"
local WRAPPER_DIRECTORY = "gradle/wrapper"
local WRAPPER_PROPERTIES = "gradle-wrapper.properties"
local DUMP_JDK = "17"
local STDERR_SHOWN = 2000

local function within(dir, name)
  if dir == nil then return name end
  return dir .. "/" .. name
end

local function derived(context, name)
  return "build/daukle/" .. context.instance .. "/" .. name
end

--- The derived directory as Gradle must be told it.
---
--- @implNote relative to the instance's own directory, not to the process's:
--- `--project-dir` also moves Gradle's current directory, and Gradle resolves
--- `--init-script` and `--project-cache-dir` against that.
local function derived_from_instance(context, name)
  local climb = ""
  for segment in string.gmatch(context.dir or "", "[^/]+") do
    if segment ~= "." then climb = climb .. "../" end
  end
  return climb .. derived(context, name)
end

local function has_file(directory, name)
  for _, entry in ipairs(daukle.list(directory) or {}) do
    if entry.name == name and entry.kind == "file" then return true end
  end
  return false
end

--- The Gradle version the wrapper names, or nil when there is no wrapper.
---
--- @implNote read from the url's last segment, because a mirror's own path can
--- hold "gradle-" as well.
local function wrapper_version(context)
  local directory = within(context.dir, WRAPPER_DIRECTORY)
  if not has_file(directory, WRAPPER_PROPERTIES) then return nil end
  local text = daukle.read(directory .. "/" .. WRAPPER_PROPERTIES)
  local url = string.match(text, "distributionUrl%s*[=:]%s*([^\r\n]+)")
  if url == nil then return nil end
  local file = string.match(url, "([^/]+)%s*$")
  return file ~= nil and string.match(file, "^gradle%-(.+)%-%a+%.zip$") or nil
end

local function model_name(build)
  if build == nil then return MODEL end
  return (string.gsub(MODEL, "%.json$", "")) .. "-" .. build .. ".json"
end

--- The model `run` dumped, parsed: the root build's, or with `build` the
--- included build's of that name (its identity path without the leading colon,
--- each further colon a hyphen).
local function read_model(context, build)
  return daukle.json_parse(daukle.read(derived(context, model_name(build))))
end

local function tail(text)
  if #text <= STDERR_SHOWN then return text end
  return "..." .. string.sub(text, -STDERR_SHOWN)
end

local function dump(context)
  daukle.write{ path = INIT_SCRIPT, text = model_dump.SCRIPT }
  local result = launcher.run(context, wrapper_version(context), DUMP_JDK, {
    "--project-dir", ".",
    "--project-cache-dir", derived_from_instance(context, PROJECT_CACHE),
    "--no-configuration-cache",
    "--init-script", derived_from_instance(context, INIT_SCRIPT),
    "-D" .. model_dump.PROPERTY .. "=" .. derived_from_instance(context, MODEL),
    "--quiet",
    "help",
  }, { cwd = context.dir or ".", capture = true, check = false })
  if result.code ~= 0 then
    error("Gradle could not configure the build, so there is no model to migrate from:\n"
          .. tail(result.stderr), 0)
  end
end

local OLD_JARS = "migrate-old"
local NEW_JARS = "build/libs"

--- The jar to compare, named as the old build's `jar` task names it.
---
--- @implNote the old side is written by `build`, which does not exist yet, so
--- until it does the proof runs the new build and then reports the old jar
--- missing; that still writes daukle.toml for inspection, which no-proof does
--- not.
local function proof_of(context, project)
  for _, task in ipairs(project.tasks or {}) do
    local values = task.values
    if task.name == "jar" and type(values) == "table" and type(values.archiveFileName) == "string" then
      return {
        task = context.instance .. ":jar",
        compare = { {
          old = derived(context, OLD_JARS .. "/" .. values.archiveFileName),
          new = derived(context, NEW_JARS .. "/" .. values.archiveFileName),
          as = "archive",
        } },
      }
    end
  end
  return nil
end

local function scope_blockers(model, where)
  local blockers = {}
  for index = 2, #model.projects do
    blockers[#blockers + 1] = { construct = model.projects[index].path, where = where,
                                why = "is a subproject, and this migrator translates a single project only so far" }
  end
  for _, build in ipairs(model.includedBuilds or {}) do
    blockers[#blockers + 1] = { construct = build.dir, where = where,
                                why = "is an included build, and this migrator translates a single project only so far" }
  end
  return blockers
end

local function run(context)
  dump(context)
  local model = read_model(context)
  local root = model.projects[1]
  local where = within(context.dir, root.buildFile or ".")
  local translation = translate_model.project(root, { model = model, dir = context.dir, where = where })
  translation.config.version = wrapper_version(context)
  local blockers = translation.blockers
  for _, blocker in ipairs(scope_blockers(model, where)) do blockers[#blockers + 1] = blocker end
  return {
    manifest = { project = translation.name, version = translation.version,
                 toolchains = { [context.instance] = translation.config } },
    foreign = {},
    blockers = blockers,
    owned = {},
    proof = proof_of(context, root),
  }
end

return { run = run, read_model = read_model }
