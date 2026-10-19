local model_dump = daukle.require("lib/model_dump")
local launcher = daukle.require("lib/launcher")

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
  for _ in string.gmatch(context.dir or "", "[^/]+") do climb = climb .. "../" end
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

local function run(context)
  dump(context)
  read_model(context)
  return {
    manifest = { toolchains = { [context.instance] = {} } },
    foreign = {},
    blockers = {},
    owned = {},
  }
end

return { run = run, read_model = read_model }
