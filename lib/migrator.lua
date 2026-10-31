local model_dump = daukle.require("lib/model_dump")
local launcher = daukle.require("lib/launcher")
local translate_build = daukle.require("lib/translate_build")
local migrate_comparison = daukle.require("lib/migrate_comparison")
local migrate_blockers = daukle.require("lib/migrate_blockers")
local migrate_paths = daukle.require("lib/migrate_paths")
local migrate_jars = daukle.require("lib/migrate_jars")
local migrate_owned = daukle.require("lib/migrate_owned")
local migrate_old_build = daukle.require("lib/migrate_old_build")
local distributions = daukle.require("lib/distributions")
local validation = daukle.require("lib/validation")
local writer = daukle.require("lib/writer")
local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")
local carried = daukle.require("lib/carried")
local migrate_carry = daukle.require("lib/migrate_carry")
local migrate_declared_configurations = daukle.require("lib/migrate_declared_configurations")
local extension_defaults = daukle.require("lib/extension_defaults")

local INIT_SCRIPT = carried.MIGRATE_PREFIX .. "model.gradle"
local MODEL = carried.MIGRATE_PREFIX .. "model.json"
local GENERATED_MODEL = carried.MIGRATE_PREFIX .. "generated-model.json"
--- The first render's model when settings code is retried carried, which the
--- retry's overwrites: a failed retry reports the first one's blockers.
local TRANSLATED_SETTINGS_MODEL = carried.MIGRATE_PREFIX .. "generated-model-settings-translated.json"
local WRAPPER_DIRECTORY = "gradle/wrapper"
local WRAPPER_PROPERTIES = "gradle-wrapper.properties"
local DUMP_JDK = "17"

--- The version a build that sets none migrates to.
---
--- @implNote core's own default for a manifest naming no version, written here
--- rather than left to core, because the jar's file name follows the version:
--- the generated build must be dumped with it, or the proof names a jar the
--- new build never writes.
local UNVERSIONED = "0.1.0"

local within = migrate_paths.within
local derived = migrate_paths.derived
local derived_from_instance = migrate_paths.derived_from_instance
local has_file = migrate_paths.has_file

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

--- @return Gradle's stderr when the run failed, else nil
local function run_dump(context, gradle_version, cwd, arguments)
  local result = launcher.run(context, gradle_version, DUMP_JDK, arguments,
                              { cwd = cwd, capture = true, check = false })
  if result.code ~= 0 then return launcher.stderr_tail(result) end
  return nil
end

local function dump(context, gradle_version)
  daukle.write{ path = INIT_SCRIPT, text = model_dump.SCRIPT }
  local failure = run_dump(context, gradle_version, context.dir or ".", {
    "--project-dir", ".",
    "--project-cache-dir", derived_from_instance(context, migrate_paths.PROJECT_CACHE),
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
           toolchain = { name = context.instance, config = config, version = config.version } }
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
    blockers[#blockers + 1] = migrate_surface.blocker(GENERATED, where, "would be refused by daukle/gradle: "
                                                      .. problem, migrate_surface.UNCOVERED_ROW)
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

local function write_generated_files(generation, config)
  for path, text in pairs(writer.generated_files(generation, config)) do
    daukle.write{ path = path, text = text }
  end
end

--- The model of the build `daukle/gradle` renders from `config`, dumped with
--- the same init script, Gradle and JDK as the old build, so the run reuses
--- the first one's daemon; or nil and the blockers that stopped it.
---
--- @implNote the writer's refusals are asked for as reasons first, because
--- the sandbox has no pcall and a raise would discard every blocker found.
--- @param blank whether carried code renders blank, for the keys-only baseline
local function dump_generated(context, built, config, where, blank)
  local rendered = rendered_config(config)
  local generation = generation_context(context, built, rendered)
  local problems = writer.generation_problems(generation, rendered)
  if #problems > 0 then return nil, generation_blockers(problems, where) end
  writer.write_build_file(generation, rendered, { blank_verbatim = blank })
  write_generated_files(generation, rendered)
  local arguments = { "--project-dir", ".", "--offline", "--no-configuration-cache", "--init-script", INIT_SCRIPT }
  if carried.settings_is_kotlin(rendered) then
    tables.append(arguments, { "--init-script", carried.KOTLIN_SETTINGS_INIT })
  end
  tables.append(arguments, { "-D" .. model_dump.PROPERTY .. "=" .. GENERATED_MODEL, "--quiet", "help" })
  local failure = run_dump(context, rendered.version, derived(context, "."), arguments)
  if failure ~= nil then
    return nil, { migrate_surface.blocker(GENERATED, where, "does not configure:\n" .. failure,
                                          migrate_surface.UNCOVERED_ROW) }
  end
  return daukle.json_parse(daukle.read(derived(context, GENERATED_MODEL))), {}
end

local append = tables.append

local SETTINGS_FILES = { "settings.gradle", "settings.gradle.kts" }

--- The settings file, relative to the instance's directory, that blockers
--- about settings name; else the root build file, else the directory itself.
local function settings_name(context, root)
  for _, name in ipairs(SETTINGS_FILES) do
    if has_file(context.dir or ".", name) then return name end
  end
  return root.buildFile or "."
end

--- What every translated project says that no key or comparison does: code
--- a build script compiled and the migration does not carry, and a toolchain
--- the proof cannot point at the provisioned JDK.
--- @param covered project -> the names of its tasks whose code is carried
local function project_blockers(built, covered)
  local blockers = {}
  local function add(project, where)
    append(blockers, migrate_blockers.build_logic(project, where, covered[project]))
    append(blockers, migrate_old_build.toolchain_blockers(project, where))
  end
  for _, entry in ipairs(built.projects) do add(entry.project, entry.where) end
  for _, record in ipairs(built.builds) do add(record.project, record.where) end
  return blockers
end

local NOTHING_CARRIED = { covered = {}, tasks = {}, statements = {}, translated = {}, fallbacks = {}, blockers = {} }

--- The generated build's model rendered from the keys alone, which is what
--- signal 2 and the selection read; or nil and the blockers that stopped it.
local function dump_baseline(context, built, linked, where)
  return dump_generated(context, built, migrate_carry.baseline_config(built.config, linked), where, true)
end

--- What the migration carries, and the generated build the comparison reads:
--- the baseline when nothing is carried, else a second render carrying it.
---
--- @implNote no second render over a stale link: the writer would refuse to
--- render the root without logic there, and its advice, `daukle clean`, is
--- one core refuses while a migration is unfinished.
local function module_of_path(built)
  local modules = {}
  for _, entry in ipairs(built.projects) do
    if entry.module ~= nil then modules[entry.project.path] = entry.module end
  end
  return modules
end

--- @implNote declared configurations are translated from the baseline before
--- the second render, which is forced when any exist so the comparison reads
--- a build that has them (spec D-203).
local function carry(context, built, blockers)
  local where = built.projects[1].where
  local linked = migrate_carry.linked_roots(context, built)
  local generated, refusals = dump_baseline(context, built, linked, where)
  if generated == nil then return NOTHING_CARRIED, nil, refusals end
  local generated_models = generated_builds(context, built)
  local carrying = migrate_carry.select(built, generated, generated_models)
  append(blockers, carrying.blockers)
  local declared, declared_blockers = migrate_declared_configurations.translate(
    migrate_carry.targets(built, generated, generated_models), module_of_path(built),
    function(place) return translate_build.block_at(built.config, place) end)
  append(blockers, declared_blockers)
  local stale = migrate_carry.stale_link_blockers(built.config, linked)
  append(blockers, stale)
  if #stale > 0 then return carrying, nil, refusals end
  if #carrying.statements == 0 and next(declared) == nil then
    return carrying, generated, refusals, generated_models
  end
  generated, refusals = dump_generated(context, built, built.config, where, false)
  if generated == nil then return carrying, nil, refusals end
  generated_models = generated_builds(context, built)
  append(blockers, migrate_declared_configurations.differences(
    migrate_carry.targets(built, generated, generated_models), declared))
  return carrying, generated, refusals, generated_models
end

--- The settings-script code of the root build and of every included build,
--- which `migrate_owned` deletes along with the file holding it.
local function settings_code_blockers(context, model, included, settings)
  local blockers = migrate_blockers.settings_code(model, within(context.dir, settings))
  for _, entry in ipairs(model.includedBuilds or {}) do
    local script = (included[entry.name] or {}).settingsScript
    if script ~= nil then
      append(blockers, migrate_blockers.settings_code(included[entry.name],
                                                      within(context.dir, entry.dir .. "/" .. script.path), entry.dir))
    end
  end
  return blockers
end

--- Each build's catalogs as the dump read them, by "root" or the included build's directory.
local function dumped_catalogs(model, included)
  local catalogs = { root = model.catalogs }
  for _, entry in ipairs(model.includedBuilds or {}) do
    catalogs[entry.dir] = (included[entry.name] or {}).catalogs
  end
  return catalogs
end

--- Each build's settings script and settings extensions as the dump read them,
--- by "root" or the included build's directory.
local function dumped_settings(model, included)
  local function of(build_model)
    return { script = build_model.settingsScript, extensions = build_model.settingsExtensions }
  end
  local settings = { root = of(model) }
  for _, entry in ipairs(model.includedBuilds or {}) do
    settings[entry.dir] = of(included[entry.name] or {})
  end
  return settings
end

local function refused(context, refusal)
  return { manifest = { toolchains = { [context.instance] = {} } }, foreign = {}, blockers = { refusal },
           owned = {} }
end

--- The proof, after writing the plan `build` runs the old jars from; a jar
--- it cannot name is added to `blockers`.
---
--- @implNote the old build runs on the JDK the new manifest's tasks run on,
--- which is the translated `jdk`, not the dump's.
local function proof_of(context, built, generated, generated_models, blockers)
  local rows, unnamed = migrate_jars.rows(context, built, generated, generated_models)
  append(blockers, unnamed)
  daukle.write{ path = migrate_jars.PLAN,
                text = migrate_jars.plan_text(rows, built.config.version, validation.jdk_version_of(built.config)) }
  return migrate_jars.proof(context, rows)
end

local function comparison_of(context, model, built, generated, generated_models, settings)
  if generated == nil then return nil end
  return migrate_comparison.blockers(model, built, generated, generated_models or {}, within(context.dir, settings),
                                     context.dir)
end

--- The translated settings statements, named beside a comparison that failed
--- with them translated and again with them carried.
local function translated_blockers(carrying, where)
  local blockers = {}
  for _, statement in ipairs(carrying.translated) do
    blockers[#blockers + 1] = migrate_surface.blocker(statement.label .. ":" .. string.format("%d", statement.line),
      where, "is settings code translated into keys, which reaches every project of its build: the comparison"
      .. " differs with it translated, and again with it carried verbatim", migrate_surface.BOUNDARY_ROW)
  end
  return blockers
end

--- The comparison's blockers, and the generated build they were read from.
---
--- @implNote when the build with its settings code translated does not compare
--- equal, it is rendered once more with that code carried, and the second
--- result stands only if it compares equal (spec D-187, 4.1a); otherwise the
--- first comparison's blockers stand, with the translated statements named.
local function compared_with_fallback(context, model, built, carrying, generated, generated_models, settings)
  local compared = comparison_of(context, model, built, generated, generated_models, settings)
  if compared == nil then return {}, generated, generated_models end
  if #compared == 0 or #carrying.fallbacks == 0 then return compared, generated, generated_models end
  daukle.write{ path = TRANSLATED_SETTINGS_MODEL, text = daukle.read(derived(context, GENERATED_MODEL)) }
  local fallback = migrate_carry.carry_translated(built, carrying)
  local retried, refusals = dump_generated(context, built, built.config, built.projects[1].where, false)
  local retried_models = retried ~= nil and generated_builds(context, built) or nil
  local second = comparison_of(context, model, built, retried, retried_models, settings)
  if second == nil or #second > 0 then
    fallback.restore()
    append(compared, translated_blockers(carrying, built.projects[1].where))
    append(compared, refusals)
    return compared, generated, generated_models
  end
  append(carrying.statements, fallback.statements)
  carrying.translated = {}
  return {}, retried, retried_models
end

--- @param defaults what `extension_defaults.read` returned, its SKIP, or nil
local function translated(model, included, context, settings, gradle_version, defaults)
  local built = translate_build.build(model, included, { dir = context.dir, settings = settings,
                                                         extensionDefaults = defaults })
  built.config.version = gradle_version
  built.version = built.version or UNVERSIONED
  built.catalogs = dumped_catalogs(model, included)
  built.settings = dumped_settings(model, included)
  return built
end

--- What every third-party extension holds when its plugin is applied and
--- nothing is set: the keys-only build rendered with no `configure` and
--- dumped. Nil when that build does not configure, so the translation falls
--- back to carrying every value, and the baseline render reports why.
local function extension_defaults_of(context, bare, model)
  local linked = migrate_carry.linked_roots(context, bare)
  local generated = dump_generated(context, bare, migrate_carry.baseline_config(bare.config, linked),
                                   bare.projects[1].where, true)
  if generated == nil then return nil end
  local real_roots = { root = model.rootDir }
  for _, record in ipairs(bare.builds) do real_roots[record.dir] = model.rootDir .. "/" .. record.dir end
  local modules = {}
  for _, module in ipairs(bare.declared or {}) do modules[#modules + 1] = module.name end
  return extension_defaults.read(generated, generated_builds(context, bare), real_roots, modules)
end

local function run(context)
  local distribution = wrapper_distribution(context)
  local refusal = gradle_refusal(context, distribution)
  if refusal ~= nil then return refused(context, refusal) end
  local gradle_version = distribution ~= nil and distribution.version or nil
  dump(context, gradle_version)
  local model = read_model(context)
  local included = included_models(context, model)
  local settings = settings_name(context, model.projects[1])
  local defaults = extension_defaults_of(context, translated(model, included, context, settings, gradle_version,
                                                             extension_defaults.SKIP), model)
  local built = translated(model, included, context, settings, gradle_version, defaults)
  local blockers = built.blockers
  append(blockers, settings_code_blockers(context, model, included, settings))
  local carrying, generated, refusals, generated_models = carry(context, built, blockers)
  append(blockers, refusals)
  append(blockers, project_blockers(built, carrying.covered))
  append(blockers, migrate_old_build.unprovided_jdk_blockers(context, built.config.jdk, built.projects[1].where))
  append(blockers, migrate_owned.blockers(context, model, included))
  local compared
  compared, generated, generated_models = compared_with_fallback(context, model, built, carrying, generated,
                                                                 generated_models, settings)
  append(blockers, compared)
  generated_models = generated_models or {}
  daukle.write{ path = migrate_carry.REPORT_SCRIPT,
                text = migrate_carry.report_script(carrying.tasks, carrying.statements, carrying.translated) }
  local proof = proof_of(context, built, generated, generated_models, blockers)
  return {
    manifest = { project = built.name, version = built.version, modules = built.modules,
                 toolchains = { [context.instance] = built.config } },
    foreign = {},
    blockers = blockers,
    owned = migrate_owned.paths(context, model, included),
    proof = proof,
  }
end

return { run = run, build = migrate_old_build.build, read_model = read_model }
