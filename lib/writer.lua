local build_file = daukle.require("lib/build_file")
local settings_file = daukle.require("lib/settings_file")
local junit = daukle.require("lib/junit")
local module_graph = daukle.require("lib/modules")
local configurations = daukle.require("lib/configurations")
local validation = daukle.require("lib/validation")
local composite = daukle.require("lib/composite")
local source_sets = daukle.require("lib/source_sets")
local builds = daukle.require("lib/builds")
local carried = daukle.require("lib/carried")
local catalogs = daukle.require("lib/catalogs")
local build_file_kotlin = daukle.require("lib/build_file_kotlin")
local verbatim = daukle.require("lib/verbatim")
local declared_configurations = daukle.require("lib/declared_configurations")
local tables = daukle.require("lib/tables")
local pinned_modules = daukle.require("lib/pinned_modules")

local joined = tables.joined

local BUILD_FILE = "build.gradle"
local SETTINGS_FILE = "settings.gradle"
local KOTLIN_SETTINGS_FILE = "settings.gradle.kts"

--- A copy of `base` carrying `extra` as well, so one table of project-wide
--- options can serve a root file and every module file without being spelled
--- again per caller.
local function extended(base, extra)
  local out = {}
  for key, value in pairs(base) do out[key] = value end
  for key, value in pairs(extra) do out[key] = value end
  return out
end

local function paths_of(entries)
  local paths = {}
  for index = 1, #entries do
    local entry = entries[index]
    paths[index] = tostring(daukle.artifact{ url = entry.url, sha256 = entry.sha256,
                                             as = entry.as })
  end
  return paths
end

--- Every entry a test run can load, in declaration order.
---
--- @implNote it spans the configurations that reach the test RUNTIME classpath,
--- because that is where a JUnit launcher has to be to be loaded. compileOnly
--- and testCompileOnly are excluded for that reason rather than by omission, so
--- a launcher declared in either is still refused.
local function test_reachable(entries)
  return configurations.test_reachable(function(key) return entries[key] end)
end

local function with_paths(sets)
  for _, set in ipairs(sets) do
    set.paths = {}
    for key, entries in pairs(set.entries) do set.paths[key] = paths_of(entries) end
  end
  return sets
end

--- The cache paths per configuration, which is the shape the renderer takes.
local function jars_of(entries, plugin_jars, named)
  local jars = { plugin = plugin_jars, named = {} }
  for index, configuration in ipairs(named) do
    jars.named[index] = { name = configuration.name, paths = paths_of(configuration.entries) }
  end
  for index = 1, #configurations.all do
    local key = configurations.all[index].key
    jars[key] = paths_of(entries[key])
  end
  return jars
end

--- @implNote written before anything that can return early, the bare discovery
--- render included: settings.gradle applies this file whenever the manifest
--- declares settings plugins or settings configure blocks, so every run that
--- starts Gradle needs it.
--- @implNote with the Kotlin settings wrapper the plugins are resolved by its
--- `plugins {}` from the local repository, so the script keeps only the
--- configure blocks: applying them again would apply each plugin twice.
local function write_settings_plugins(config, owners)
  local declared = validation.settings_plugins_of(config, owners)
  if declared == nil then return end
  local jars = paths_of(declared.entries)
  if not carried.settings_is_kotlin(config) then
    return daukle.write{ path = settings_file.SCRIPT,
                         text = settings_file.settings_plugins(jars, declared.plugins, declared.configure) }
  end
  local repository = settings_file.settings_repository(jars)
  for _, file in ipairs(repository.files) do daukle.write{ path = file.path, text = file.text } end
  daukle.write{ path = carried.SETTINGS_REPOSITORY_JARS, text = repository.copies }
  daukle.write{ path = settings_file.SCRIPT, text = settings_file.settings_plugins({}, {}, declared.configure) }
end

--- The Groovy render of one project of a carrying build, plain or for a wrapper.
---
--- @param depth_name the name the project's paths start with, nil for a main root
--- @param script_name the name its files are written under, nil for any root
local function real_tree_render(depth_name, script_name, layout, jars, options)
  return function(wrapped)
    return build_file.real_tree_project(depth_name, layout, jars, extended(options, {
      real_tree = { build_directory = carried.build_directory_of(script_name), wrapped = wrapped },
    }))
  end
end

--- One project of a carrying build: its render alone, its render with the
--- carried Groovy after it, or a Kotlin wrapper applying the render.
---
--- @param project { directory, name, verbatim = <what verbatim.checked returned>, render = function(wrapped), ids }
--- @param blank whether the carried code renders as no text and no warn line,
--- which is the task set the keys alone give
local function write_carrying_project(project, blank)
  local script = project.directory .. carried.script_of(project.name, project.verbatim)
  if project.verbatim == nil then
    return daukle.write{ path = script, text = project.render(false) }
  end
  local text, warn_line = "", nil
  if not blank then text, warn_line = project.verbatim.text, verbatim.warn_line(project.verbatim) end
  if not carried.is_kotlin(project.verbatim) then
    local warning = warn_line ~= nil and warn_line .. "\n" or ""
    return daukle.write{ path = script, text = project.render(false) .. "\n" .. warning .. text }
  end
  local rendered = carried.rendered_of(project.name)
  daukle.write{ path = project.directory .. rendered, text = project.render(true) }
  daukle.write{ path = script, text = build_file_kotlin.wrapper(project.ids, rendered, text, warn_line) }
end

local function write_carrying_included_build(build, at, jars, options, place)
  daukle.write{ path = at .. "/" .. carried.ROOT_LINKS,
                text = settings_file.root_links(carried.real_directory_of_included(build.name, place.root)) }
  daukle.write{ path = at .. "/settings.gradle",
                text = settings_file.included_real_tree_settings(build.gradle_name,
                                                                 carried.script_of(nil, build.verbatim),
                                                                 build.catalogs, build.settings_verbatim) }
  for _, file in ipairs(catalogs.files_of(build.catalogs)) do
    daukle.write{ path = at .. "/" .. file.path, text = file.text }
  end
  write_carrying_project({ directory = at .. "/", verbatim = build.verbatim,
                           render = real_tree_render(build.name, nil, build.layout, jars, options),
                           ids = build_file.plugin_ids(jars, options) }, place.blank)
end

--- @implNote written on every run, the bare discovery render included:
--- settings.gradle includes every declared build, so Gradle fails on any run
--- that starts without them.
--- @param place { root = <context.root>, instance, blank = <whether carried code renders blank> }
local function write_included_builds(checked, named_of, place)
  for index = 1, #checked do
    local build = checked[index]
    local at = composite.path_of(build.name)
    junit.refuse_a_missing_launcher(test_reachable(build.entries))
    local jars = jars_of(build.entries, {}, named_of(build.named))
    local options = { release = build.release, test_framework = build.test_framework, plugins = {},
                      gradle_plugins = build.gradle_plugins, pinned_modules = pinned_modules.of(build.entries, build.named),
                      group = (not build.plugin_build) and composite.GROUP or nil,
                      library = not build.plugin_build,
                      declared_configurations = build.declared_configurations }
    if build.verbatim ~= nil or build.settings_verbatim ~= nil then
      write_carrying_included_build(build, at, jars, options, place)
    else
      carried.refuse_a_linked_root(carried.derived_of(place.instance) .. "/" .. at)
      daukle.write{ path = at .. "/settings.gradle",
                    text = settings_file.included_settings(build.gradle_name) }
      daukle.write{ path = at .. "/" .. BUILD_FILE,
                    text = build_file.included(build.name, build.layout, jars, options) }
    end
  end
end

--- @implNote per module, because a module carries its own testClasspath: a
--- project-wide check would pass while one module's test runtime held a
--- platform engine and no launcher, which is the declaration that passes on
--- Gradle 8 and dies on the next major.
--- What the root's (`name` nil) or an implicit parent's block renders, or nil
--- for none or for a bare render, which leaves out every plugin.
local function parent_options(build, name)
  if build.bare then return nil end
  local found = build.parents[name or ""]
  if found == nil then return nil end
  return { plugins = found.plugins.pinned, core_plugins = found.plugins.core,
           included_plugins = found.plugins.included, configure = found.configure }
end

local function refuse_a_module_missing_launcher(module)
  junit.refuse_a_missing_launcher(test_reachable(module.entries))
end

--- The project-wide options with a module's own composed in, as Gradle composes
--- `subprojects {}` with a project's own script (D-168): plugins after the
--- project-wide ones, configure blocks after theirs, release and sourcesJar
--- already resolved against their project-wide fallback.
local function module_options(build, module)
  local project_wide = build.project_wide
  local own = build.bare and { pinned = {}, included = {}, core = {} } or module.plugins
  return extended(project_wide, { release = module.release,
                                  sources_jar = module.sources_jar,
                                  test_framework = module.test_framework,
                                  plugins = joined(project_wide.plugins, own.pinned),
                                  core_plugins = joined(project_wide.core_plugins, own.core),
                                  included_plugins = joined(project_wide.included_plugins, own.included),
                                  module_configure = (not build.bare) and module.configure or nil,
                                  main = module.main,
                                  requires = module.requires,
                                  required_builds = module.required_builds,
                                  source_sets = with_paths(module.source_sets),
                                  declared_configurations = module.declared_configurations,
                                  project_dependencies = module.project_dependencies,
                                  pinned_modules = pinned_modules.of(module.entries, module.named) })
end

--- @implNote the root file is written on every multi-project run, carrying only
--- its header when there is no plugin classpath. A task's write is not in
--- core's generate ledger and core prunes nothing, so a single-project build
--- file an earlier build left at the derived root would otherwise stay the root
--- project of this one, with its own source roots, its own jar and its own
--- daukleRun. An undeclared parent of a nested module gets a header-only file
--- for the same reason: it was a module once, and Gradle would read what that
--- run left in its directory.
local function write_today(build)
  carried.refuse_a_linked_root(carried.derived_of(build.instance))
  if #build.declared == 0 then
    return daukle.write{
      path = BUILD_FILE,
      text = build_file.render(validation.layout_of(build.config),
                               jars_of(build.entries, build.plugin_jars,
                                       build.named_of(configurations.named(build.config, ""))),
                               build.root_options),
    }
  end

  daukle.write{ path = BUILD_FILE,
                text = build_file.parent_project(build.plugin_jars, parent_options(build, nil), build_file.ROOT) }

  for _, module in ipairs(build.modules) do
    refuse_a_module_missing_launcher(module)
    daukle.write{
      path = module.name .. "/" .. BUILD_FILE,
      text = build_file.module(module.name, module.layout,
                               jars_of(module.entries, {}, build.named_of(module.named)),
                               module_options(build, module)),
    }
  end

  for _, parent in ipairs(module_graph.undeclared_parents(build.declared)) do
    daukle.write{ path = parent .. "/" .. BUILD_FILE,
                  text = build_file.parent_project({}, parent_options(build, parent), build_file.root_of(parent)) }
  end
end

local function write_carrying_root(build, root_jars)
  local config = build.config
  local root_verbatim = carried.root_of(config)
  if #build.declared > 0 then
    local options = parent_options(build, nil)
    return write_carrying_project({ directory = "", verbatim = root_verbatim,
                                    render = function(wrapped)
                                      return build_file.real_tree_header(root_jars, options, wrapped)
                                    end,
                                    ids = build_file.parent_ids(options) }, build.blank)
  end
  local jars = jars_of(build.entries, root_jars, build.named_of(configurations.named(config, "")))
  write_carrying_project({ directory = "", verbatim = root_verbatim,
                           render = real_tree_render(nil, nil, validation.layout_of(config), jars,
                                                     build.root_options),
                           ids = build_file.plugin_ids(jars, build.root_options) },
                         build.blank)
end

--- Every project in its real directory, its files under `build/scripts/`.
---
--- @implNote with the classpath in settings.gradle no project file declares
--- one, since every project's classloader already has it.
local function write_real_tree(build)
  local in_settings = carried.classpath_in_settings(build.config)
  if in_settings and not build.bare then
    daukle.write{ path = carried.PLUGIN_CLASSPATH,
                  text = table.concat(build.plugin_jars, "\n") .. "\n" }
  end
  write_carrying_root(build, in_settings and {} or build.plugin_jars)
  for _, module in ipairs(build.modules) do
    refuse_a_module_missing_launcher(module)
    local jars = jars_of(module.entries, {}, build.named_of(module.named))
    local options = module_options(build, module)
    write_carrying_project({ directory = "", name = module.name, verbatim = module.verbatim,
                             render = real_tree_render(module.name, module.name, module.layout,
                                                       jars, options),
                             ids = build_file.plugin_ids(jars, options) }, build.blank)
  end
  for _, parent in ipairs(module_graph.undeclared_parents(build.declared)) do
    daukle.write{ path = carried.script_of(parent, nil),
                  text = build_file.parent_project({}, parent_options(build, parent), carried.depth_of(parent)) }
  end
end

--- What settings.gradle names for a build that carries code, or nil.
local function real_tree_settings(context, config, declared)
  if not carried.build_carries(config) then return nil end
  local projects = {}
  for _, module in ipairs(declared) do
    projects[#projects + 1] = { name = module.name,
                                script = carried.script_of(module.name, carried.module_of(config, module.name)) }
  end
  for _, parent in ipairs(module_graph.undeclared_parents(declared)) do
    projects[#projects + 1] = { name = parent, script = carried.script_of(parent, nil) }
  end
  local instance = validation.instance_of(context)
  return { root_script = carried.script_of(nil, carried.root_of(config)), real_root = context.root,
           settings_verbatim = carried.settings_of(config),
           derived = carried.derived_from_real_root(context.root, instance),
           catalogs = validation.checked_catalogs(context, config),
           classpath_file = carried.classpath_in_settings(config) and carried.PLUGIN_CLASSPATH or nil,
           projects = projects }
end

--- Every build file Gradle reads, written into the derived directory.
---
--- `options` is how a discovery run differs from an ordinary one: it may
--- suppress the apply lines and the configure blocks, and it names the marker
--- the generated listing task prints with. Everything else about the two files
--- is identical on purpose, so the difference between their task lists is what
--- the plugins contributed and nothing else. `without_named` leaves every
--- `configurations.<name>` pin out, so Gradle reports the default a pin would hide.
---
--- @implNote `release`, `plugins` and `configure` are project-wide and are
--- rendered into EVERY module rather than into an `allprojects {}` block: the
--- renderer is the only writer, so the duplication costs a reader nothing and
--- there is no second configuration mechanism to learn.
--- @implNote `options.blank_verbatim` renders every carried project with no
--- carried text, which the migrator's baseline needs; `bare` implies it, since
--- that render leaves out the plugins carried code may name.
local function write_build_file(context, config, options)
  --[[ Again here and not only in generate: a task is reachable without a sync,
       so a check that only ran there would be a check a user can walk past. ]]
  validation.validated(context, config)
  local composite_record = validation.composite_of(context, config)
  local without_named = options ~= nil and options.without_named or false
  local bare = options ~= nil and options.bare or false
  local function named_of(named)
    if bare or without_named then return {} end
    return named
  end
  local blank = bare or (options ~= nil and options.blank_verbatim) or false
  local place = { root = context.root, instance = validation.instance_of(context), blank = blank }
  if carried.settings_is_kotlin(config) then
    daukle.write{ path = carried.KOTLIN_SETTINGS_INIT, text = settings_file.KOTLIN_SETTINGS_INIT }
  end
  write_settings_plugins(config, composite_record.owners)
  write_included_builds(composite_record.builds, named_of, place)
  --[[ Not `bare and nil or config.configure`: in Lua that is config.configure
       for both values of bare, because nil is false. ]]
  local configure = config.configure
  if bare then configure = nil end
  local entries = validation.entries_of_configurations(config, "")
  junit.refuse_a_missing_launcher(test_reachable(entries))

  --[[ Built once and extended per file rather than spelled once per branch: a
       project-wide key added to one of two copies is a key half the projects
       get, and `plugins` was also revalidated once per module. ]]
  local plugin_jars = bare and {}
                      or paths_of(validation.checked_classpath(config.pluginClasspath,
                                                               "pluginClasspath"))
  local project_options = module_graph.project_options(config)
  local pinned_plugins, core_plugins = {}, {}
  if not bare then
    local pinned, _, core = validation.checked_plugins(config.plugins, "plugins",
                                                       composite_record.owners)
    pinned_plugins, core_plugins = pinned, core
  end
  local project_wide = { release = project_options.release,
                         sources_jar = project_options.sources_jar,
                         test_framework = project_options.test_framework,
                         version = context.version,
                         plugins = pinned_plugins,
                         core_plugins = core_plugins,
                         included_plugins = bare and {} or composite_record.project_ids,
                         configure = configure,
                         discover = options ~= nil and options.discover or nil }

  local build = {
    config = config, entries = entries, plugin_jars = plugin_jars, named_of = named_of,
    project_wide = project_wide, blank = blank, bare = bare, instance = place.instance,
    root_options = extended(project_wide,
                            { main = project_options.main,
                              required_builds = composite_record.required,
                              source_sets = with_paths(source_sets.read(config, nil)),
                              declared_configurations = declared_configurations.read(config, "", {}),
                              pinned_modules = pinned_modules.of(entries, configurations.named(config, "")) }),
    declared = module_graph.declared(context),
  }
  build.parents = {}
  for _, found in ipairs(validation.checked_parents(config, build.declared, composite_record.owners)) do
    build.parents[found.name or ""] = found
  end
  build.modules = #build.declared > 0
                  and validation.checked_modules(config, build.declared, composite_record.read)
                  or {}
  if carried.build_carries(config) then return write_real_tree(build) end
  write_today(build)
end

--- The files generate returns: settings.gradle, and for a build that carries
--- code the root links script it applies and the catalogs it declares. The
--- migrator writes the same text for its task-set comparison, so both read
--- one renderer.
local function settings_text(context, config)
  local record = validation.composite_of(context, config)
  local applies_settings_plugins = validation.settings_plugins_of(config, record.owners) ~= nil
  local declared = module_graph.declared(context)
  return settings_file.settings(validation.project_name(context), declared,
                                applies_settings_plugins, record,
                                real_tree_settings(context, config, declared))
end

--- The settings files for a build whose settings carry Kotlin: the wrapper,
--- and the Groovy render it applies.
local function kotlin_settings_files(context, config)
  local record = validation.composite_of(context, config)
  local declared = validation.settings_plugins_of(config, record.owners)
  local real_tree = real_tree_settings(context, config, module_graph.declared(context))
  return {
    [KOTLIN_SETTINGS_FILE] = settings_file.kotlin_wrapper(record, real_tree, declared ~= nil and declared.plugins or {}),
    [carried.SETTINGS_RENDERED] = settings_text(context, config),
  }
end

local function generated_files(context, config)
  local files = carried.settings_is_kotlin(config) and kotlin_settings_files(context, config)
                or { [SETTINGS_FILE] = settings_text(context, config) }
  if carried.build_carries(config) then
    files[carried.ROOT_LINKS] = settings_file.root_links(context.root)
    for _, file in ipairs(catalogs.files_of(validation.checked_catalogs(context, config))) do
      files[file.path] = file.text
    end
  end
  return files
end

local function append_launcher_problem(problems, entries)
  local launcher = junit.missing_launcher(test_reachable(entries))
  if launcher ~= nil then problems[#problems + 1] = launcher end
end

--- The JUnit launcher and the one-main rule, per module and per included
--- build, since each carries its own test classpath.
local function per_project_problems(config, declared, problems)
  local blocks = config.modules or {}
  local mains = {}
  for _, module in ipairs(declared) do
    local block = blocks[module.name] or {}
    mains[#mains + 1] = { name = module.name, main = block.main }
    append_launcher_problem(problems, validation.entries_of_configurations(block, "modules." .. module.name .. "."))
  end
  local two_mains = module_graph.two_mains_problem(mains)
  if two_mains ~= nil then problems[#problems + 1] = two_mains end
  for name, block in pairs(config.builds or {}) do
    append_launcher_problem(problems, validation.entries_of_configurations(block, "builds." .. name .. "."))
  end
end

local function sorted_names(blocks)
  local names = {}
  for name, block in pairs(type(blocks) == "table" and blocks or {}) do
    if type(block) == "table" then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

local function append_verbatim_problems(config, problems)
  local function add(problem)
    if problem ~= nil then problems[#problems + 1] = problem end
  end
  add((verbatim.problem_of(config.verbatim, "verbatim")))
  add((verbatim.problem_of(config.settingsVerbatim, "settingsVerbatim")))
  for _, family in ipairs({ "modules", "builds" }) do
    for _, name in ipairs(sorted_names(config[family])) do
      add((verbatim.problem_of(config[family][name].verbatim, family .. "." .. name .. ".verbatim")))
    end
  end
  for _, name in ipairs(sorted_names(config.builds)) do
    add(verbatim.included_settings_problem_of(config.builds[name].settingsVerbatim,
                                              "builds." .. name .. ".settingsVerbatim"))
  end
end

--- What `write_build_file` would refuse in this config, as reasons rather
--- than a raise, for the migrator, which reports a refusal as a blocker.
---
--- @implNote the refusals a translated config can meet: its module graph and
--- included builds, its plugin lists and their classpaths, its configure trees,
--- the JUnit launcher and two modules declaring `main`. Every other check in
--- `validated` is on a shape the translation never writes. A refused graph or
--- build list is returned alone, because every later check reads them.
local function generation_problems(context, config)
  local retired = verbatim.retired_problem(config, validation.instance_of(context))
  if retired ~= nil then return { retired } end
  local graph = module_graph.declared_problem(context)
  if graph ~= nil then return { graph } end
  local declared = module_graph.declared(context)
  local read = builds.read_problem(config, declared, validation.project_name(context))
  if read ~= nil then return { read } end
  local problems = validation.plugin_set_problems(context, config)
  append_launcher_problem(problems, validation.entries_of_configurations(config, ""))
  per_project_problems(config, declared, problems)
  append_verbatim_problems(config, problems)
  return problems
end

return {
  SETTINGS_FILE = SETTINGS_FILE,
  generated_files = generated_files,
  generation_problems = generation_problems,
  settings_text = settings_text,
  write_build_file = write_build_file,
}
