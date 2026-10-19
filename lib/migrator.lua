local model_dump = daukle.require("lib/model_dump")
local launcher = daukle.require("lib/launcher")
local translate_model = daukle.require("lib/translate_model")
local migrate_blockers = daukle.require("lib/migrate_blockers")
local distributions = daukle.require("lib/distributions")
local writer = daukle.require("lib/writer")

local INIT_SCRIPT = "migrate-model.gradle"
local MODEL = "migrate-model.json"
local GENERATED_MODEL = "migrate-generated-model.json"
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

local function trimmed(text)
  return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

--- The distribution the wrapper names: nil when there is no wrapper or it
--- names no url, else { url, version }, version nil when the url is not one
--- this can read.
---
--- @implNote the version is read from the url's last segment, because a
--- mirror's own path can hold "gradle-" as well. The url is unescaped as a
--- properties value, where the wrapper writes `https\://`.
local function wrapper_distribution(context)
  local directory = within(context.dir, WRAPPER_DIRECTORY)
  if not has_file(directory, WRAPPER_PROPERTIES) then return nil end
  local text = daukle.read(directory .. "/" .. WRAPPER_PROPERTIES)
  local url = string.match(text, "distributionUrl%s*[=:]%s*([^\r\n]+)")
  if url == nil then return nil end
  url = string.gsub(trimmed(url), "\\(.)", "%1")
  local file = string.match(url, "([^/]+)$")
  return { url = url, version = file ~= nil and string.match(file, "^gradle%-(.+)%-%a+%.zip$") or nil }
end

--- Why the wrapper's Gradle cannot be provisioned, or nil when it can.
---
--- @implNote decided before anything is provisioned: the dump itself runs on
--- that Gradle, and an unpinned one is never fetched.
local function gradle_refusal(context, distribution)
  if distribution == nil then return nil end
  local where = within(context.dir, WRAPPER_DIRECTORY .. "/" .. WRAPPER_PROPERTIES)
  if distribution.version == nil then
    return migrate_blockers.unreadable_distribution(distribution.url, where)
  end
  if not distributions.is_pinned(distribution.version) then
    return migrate_blockers.unpinned_gradle(distribution.version, where)
  end
  return nil
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

--- @return Gradle's stderr when the run failed, else nil
local function run_dump(context, gradle_version, cwd, arguments)
  local result = launcher.run(context, gradle_version, DUMP_JDK, arguments,
                              { cwd = cwd, capture = true, check = false })
  if result.code ~= 0 then return tail(result.stderr) end
  return nil
end

local function dump(context, gradle_version)
  daukle.write{ path = INIT_SCRIPT, text = model_dump.SCRIPT }
  local failure = run_dump(context, gradle_version, context.dir or ".", {
    "--project-dir", ".",
    "--project-cache-dir", derived_from_instance(context, PROJECT_CACHE),
    "--no-configuration-cache",
    "--init-script", derived_from_instance(context, INIT_SCRIPT),
    "-D" .. model_dump.PROPERTY .. "=" .. derived_from_instance(context, MODEL),
    "--quiet",
    "help",
  })
  if failure ~= nil then
    error("Gradle could not configure the build, so there is no model to migrate from:\n" .. failure, 0)
  end
end

--- The context a task of the translated manifest would see, which is what the
--- plugin's own renderer reads.
local function generation_context(context, translation, config)
  return { instance = context.instance, dir = context.dir, root = context.root, host = context.host,
           project = translation.name, version = translation.version, modules = {},
           toolchain = { config = config, version = config.version } }
end

--- The translated config without `jdk`, which picks only the JVM a task runs
--- Gradle on and is not rendered: the comparison dump runs on the dump's JDK.
local function rendered_config(config)
  local copy = {}
  for key, value in pairs(config) do copy[key] = value end
  copy.jdk = nil
  return copy
end

local GENERATED = "the generated build"

local function generation_blockers(problems, where)
  local blockers = {}
  for _, problem in ipairs(problems) do
    blockers[#blockers + 1] = { construct = GENERATED, where = where,
                                why = "would be refused by daukle/gradle: " .. problem }
  end
  return blockers
end

--- The model of the build `daukle/gradle` renders from the translation,
--- dumped with the same init script, Gradle and JDK as the old build, so the
--- run reuses the first one's daemon; or nil and the blockers that stopped it.
---
--- @implNote the writer's refusals are asked for as reasons first, because
--- the sandbox has no pcall and a raise would discard every blocker found.
local function dump_generated(context, translation, where)
  local config = rendered_config(translation.config)
  local generation = generation_context(context, translation, config)
  local problems = writer.generation_problems(generation, config)
  if #problems > 0 then return nil, generation_blockers(problems, where) end
  writer.write_build_file(generation, config)
  daukle.write{ path = writer.SETTINGS_FILE, text = writer.settings_text(generation, config) }
  local failure = run_dump(context, config.version, derived(context, "."), {
    "--project-dir", ".",
    "--offline",
    "--no-configuration-cache",
    "--init-script", INIT_SCRIPT,
    "-D" .. model_dump.PROPERTY .. "=" .. GENERATED_MODEL,
    "--quiet",
    "help",
  })
  if failure ~= nil then
    return nil, { { construct = GENERATED, where = where, why = "does not configure:\n" .. failure } }
  end
  return daukle.json_parse(daukle.read(derived(context, GENERATED_MODEL))), {}
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

local function append(target, source)
  for _, item in ipairs(source) do target[#target + 1] = item end
end

local function refused(context, refusal)
  return { manifest = { toolchains = { [context.instance] = {} } }, foreign = {}, blockers = { refusal },
           owned = {} }
end

local function run(context)
  local distribution = wrapper_distribution(context)
  local refusal = gradle_refusal(context, distribution)
  if refusal ~= nil then return refused(context, refusal) end
  local gradle_version = distribution ~= nil and distribution.version or nil
  dump(context, gradle_version)
  local model = read_model(context)
  local root = model.projects[1]
  local where = within(context.dir, root.buildFile or ".")
  local translation = translate_model.project(root, { model = model, dir = context.dir, where = where })
  translation.config.version = gradle_version
  local blockers = translation.blockers
  append(blockers, scope_blockers(model, where))
  append(blockers, migrate_blockers.build_logic(root, where))
  local generated, refusals = dump_generated(context, translation, where)
  append(blockers, refusals)
  if generated ~= nil then
    append(blockers, migrate_blockers.core_plugins(root, generated.projects[1], where))
    append(blockers, migrate_blockers.task_difference(root, generated.projects[1], where))
  end
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
