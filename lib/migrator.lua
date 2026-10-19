local model_dump = daukle.require("lib/model_dump")
local launcher = daukle.require("lib/launcher")
local translate_build = daukle.require("lib/translate_build")
local migrate_comparison = daukle.require("lib/migrate_comparison")
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
--- properties value, where the wrapper writes `https\://`, and only a line
--- that starts with the key counts, so a `#distributionUrl=` comment does not.
local function wrapper_distribution(context)
  local directory = within(context.dir, WRAPPER_DIRECTORY)
  if not has_file(directory, WRAPPER_PROPERTIES) then return nil end
  local text = daukle.read(directory .. "/" .. WRAPPER_PROPERTIES)
  local url = string.match("\n" .. text, "[\r\n][ \t]*distributionUrl%s*[=:]%s*([^\r\n]+)")
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

local function model_name(base, build)
  if build == nil then return base end
  return (string.gsub(base, "%.json$", "")) .. "-" .. (string.gsub(build, ":", "-")) .. ".json"
end

--- The model `run` dumped, parsed: the root build's, or with `build` the
--- included build's of that name (its identity path without the leading colon,
--- each further colon a hyphen).
local function read_model(context, build)
  return daukle.json_parse(daukle.read(derived(context, model_name(MODEL, build))))
end

local function derived_has(context, name)
  return has_file("build/daukle/" .. context.instance, name)
end

--- Each included build's model by the name `includedBuilds` gives it, left
--- out when the dump wrote none: the translation blocks that build by name.
local function included_models(context, model)
  local models = {}
  for _, entry in ipairs(model.includedBuilds or {}) do
    if derived_has(context, model_name(MODEL, entry.name)) then models[entry.name] = read_model(context, entry.name) end
  end
  return models
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
local function generation_context(context, built, config)
  return { instance = context.instance, dir = context.dir, root = context.root, host = context.host,
           project = built.name, version = built.version, modules = built.declared or {},
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

local function last_component(path)
  return string.match(path, "([^/]+)$") or path
end

--- Each generated included build's model by its directory, found under the
--- name Gradle gave the build, which is its root project's or its directory's.
local function generated_builds(context, built)
  local models = {}
  for _, record in ipairs(built.builds) do
    for _, name in ipairs({ record.gradle_name, last_component(record.dir) }) do
      local file = model_name(GENERATED_MODEL, name)
      if models[record.dir] == nil and derived_has(context, file) then
        models[record.dir] = { identity = ":" .. name,
                               model = daukle.json_parse(daukle.read(derived(context, file))) }
      end
    end
  end
  return models
end

--- The model of the build `daukle/gradle` renders from the translation,
--- dumped with the same init script, Gradle and JDK as the old build, so the
--- run reuses the first one's daemon; or nil and the blockers that stopped it.
---
--- @implNote the writer's refusals are asked for as reasons first, because
--- the sandbox has no pcall and a raise would discard every blocker found.
local function dump_generated(context, built, where)
  local config = rendered_config(built.config)
  local generation = generation_context(context, built, config)
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

local function jar_name(project)
  for _, task in ipairs(project.tasks or {}) do
    local values = task.values
    if task.name == "jar" and type(values) == "table" and type(values.archiveFileName) == "string" then
      return values.archiveFileName
    end
  end
  return nil
end

local function under(module, path)
  if module == nil then return path end
  return module .. "/" .. path
end

--- One jar to compare per project that becomes the root or a module, named as
--- the old build's `jar` task names it.
---
--- @implNote the old side is written by `build`, which does not exist yet, so
--- until it does the proof runs the new build and then reports the old jars
--- missing; that still writes daukle.toml for inspection, which no-proof does
--- not.
local function proof_of(context, built)
  local compare = {}
  for _, entry in ipairs(built.projects) do
    local name = jar_name(entry.project)
    if name ~= nil and (entry.module ~= nil or built.declared == nil) then
      compare[#compare + 1] = { old = derived(context, OLD_JARS .. "/" .. under(entry.module, name)),
                                new = derived(context, under(entry.module, NEW_JARS .. "/" .. name)),
                                as = "archive" }
    end
  end
  if #compare == 0 then return nil end
  return { task = context.instance .. ":jar", compare = compare }
end

local function append(target, source)
  for _, item in ipairs(source) do target[#target + 1] = item end
end

local SETTINGS_FILES = { "settings.gradle", "settings.gradle.kts" }

--- The settings file, relative to the instance's directory, that blockers
--- about settings name; else the root build file, else the directory itself.
local function settings_name(context, root)
  for _, name in ipairs(SETTINGS_FILES) do
    if has_file(context.dir or ".", name) then return name end
  end
  return root.buildFile or "."
end

local function build_logic_blockers(built)
  local blockers = {}
  for _, entry in ipairs(built.projects) do append(blockers, migrate_blockers.build_logic(entry.project, entry.where)) end
  for _, record in ipairs(built.builds) do append(blockers, migrate_blockers.build_logic(record.project, record.where)) end
  return blockers
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
  local settings = settings_name(context, model.projects[1])
  local built = translate_build.build(model, included_models(context, model),
                                      { dir = context.dir, settings = settings })
  built.config.version = gradle_version
  local blockers = built.blockers
  append(blockers, build_logic_blockers(built))
  local settings_where = within(context.dir, settings)
  local generated, refusals = dump_generated(context, built, built.projects[1].where)
  append(blockers, refusals)
  if generated ~= nil then
    append(blockers, migrate_comparison.blockers(model, built, generated, generated_builds(context, built),
                                                 settings_where))
  end
  return {
    manifest = { project = built.name, version = built.version, modules = built.modules,
                 toolchains = { [context.instance] = built.config } },
    foreign = {},
    blockers = blockers,
    owned = {},
    proof = proof_of(context, built),
  }
end

return { run = run, read_model = read_model }
