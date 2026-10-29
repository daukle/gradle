--- One Gradle project of the dumped model, translated into `[toolchains.gradle]`
--- keys, with every dependency pinned and a blocker for whatever the keys
--- cannot say.
---
--- @implNote dependencies are translated from the RESOLVED classpaths, not the
--- declarations, because `daukle/gradle` hands Gradle files and resolves
--- nothing: every transitive artifact has to be pinned, and a configuration
--- the build wired with `extendsFrom` shows up as the artifacts it brought.
--- Which declaration reached a row decides `api` and `compileOnlyApi`, which
--- no resolved classpath can tell from `implementation` and `compileOnly`
--- (lib/translate_dependencies).

local translate_model = {}

local translation_state = daukle.require("lib/translation")
local translate_plugins = daukle.require("lib/translate_plugins")
local translate_dependencies = daukle.require("lib/translate_dependencies")
local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")

local LAYOUT_ROW = migrate_surface.LAYOUT_ROW
local as_set = tables.as_set
local sorted_keys = tables.sorted_keys

local MAIN = "main"
local TEST = "test"
local SOURCES_JAR_TASK = "sourcesJar"
local JAR_TASK = "jar"
local UNSPECIFIED = "unspecified"
local HIGH_BYTE = "[\128-\255]"

--- @implNote JEP 400: javac reads sources as UTF-8 by default from JDK 18 on.
local UTF8_BY_DEFAULT_FROM = 18

local ROOT_KEYS = {
  main = { java = "sourceRoot", resources = "resourceRoot" },
  test = { java = "testSourceRoot", resources = "testResourceRoot" },
}

local block = translation_state.block
local carried = translation_state.carried
local is_unrendered = translation_state.is_unrendered

local function extension_value(project, name)
  local extension = (project.extensions or {})[name]
  if extension == nil or is_unrendered(extension.value) then return nil end
  return extension.value
end

local function task_values(project, name)
  local task = tables.named(project.tasks, name)
  if task == nil or is_unrendered(task.values) then return {} end
  return task.values or {}
end

local function whole_number(value)
  if type(value) == "number" then return string.format("%.0f", value) end
  return value
end

local function language_version(project)
  local java = extension_value(project, "java")
  return java ~= nil and java.toolchain ~= nil and whole_number(java.toolchain.languageVersion) or nil
end

--- @implNote "1.8" is how `JavaVersion` spells 8, and `release` takes the bare number.
local function release_level(value)
  if type(value) ~= "string" then return whole_number(value) end
  if string.sub(value, 1, 2) == "1." then return string.sub(value, 3) end
  return value
end

local function dump_major(model)
  local version = (model.jvm or {}).javaVersion or ""
  return string.match(version, "^1%.(%d+)") or string.match(version, "^(%d+)")
end

--- The level the build itself set for `raw_key`, or nil when it set none.
---
--- @implNote when the raw value cannot be read, a level equal to the dump
--- daemon's JDK in a build with no toolchain is taken as unset, because that
--- is where Gradle's evaluated value comes from then.
local function compatibility_set(translation, project, java, raw_key, evaluated_key)
  local raw = java[raw_key]
  if not is_unrendered(raw) then return release_level(raw) end
  local evaluated = release_level(java[evaluated_key])
  if language_version(project) == nil and evaluated == dump_major(translation.model) then return nil end
  return evaluated
end

local function translate_release(translation, project, compile_task)
  local values = task_values(project, compile_task)
  if values.release ~= nil then
    return carried(translation, release_level(values.release), compile_task .. ".options.release")
  end
  local java = extension_value(project, "java") or {}
  local source_set = compatibility_set(translation, project, java, "rawSourceCompatibility", "sourceCompatibility")
  local target_set = compatibility_set(translation, project, java, "rawTargetCompatibility", "targetCompatibility")
  if source_set == nil and target_set == nil then return nil end
  local source = source_set or release_level(java.sourceCompatibility)
  local target = target_set or release_level(java.targetCompatibility)
  if target ~= nil and target ~= source then
    block(translation, "java.targetCompatibility", "is " .. target .. " while sourceCompatibility is "
          .. source .. ", and the release key sets both to one level", LAYOUT_ROW)
    return nil
  end
  return carried(translation, source, "java.sourceCompatibility")
end

local function translate_main(translation, project)
  local application = extension_value(project, "application")
  if application ~= nil and type(application.mainClass) == "string" then
    return carried(translation, application.mainClass, "application.mainClass")
  end
  local attributes = task_values(project, JAR_TASK).manifestAttributes
  if type(attributes) == "table" and type(attributes["Main-Class"]) == "string" then
    return carried(translation, attributes["Main-Class"], "jar.manifest.attributes.Main-Class")
  end
  return nil
end

local function is_absolute(path)
  return string.sub(path, 1, 1) == "/" or string.match(path, "^%a:/") ~= nil
end

--- A model path (relative to the build's root) as a source root key holds
--- it, relative to the daukle project's root, or nil when it lies outside it.
local function within_project(translation, path)
  if is_absolute(path) or path == ".." or string.sub(path, 1, 3) == "../" then return nil end
  return translation.prefix .. path
end

--- Where a set's root lies when the key is left out: under the module's or
--- the included build's own directory, else under the project's root.
local function default_root(translation, set_name, kind)
  local owner = translation.name ~= nil and (translation.name .. "/") or ""
  return owner .. "src/" .. set_name .. "/" .. kind
end

local function same_list(left, right)
  if #left ~= #right then return false end
  for index = 1, #left do
    if left[index] ~= right[index] then return false end
  end
  return true
end

local function one_or_list(paths)
  if #paths == 1 then return paths[1] end
  return paths
end

--- A model path inside the project's build directory as the `buildOutput`
--- marker that names it relative to that directory, or nil when it lies
--- elsewhere.
---
--- @implNote a carrying render redirects the build directory, so a generated
--- root kept as a project path would name a directory nothing writes (D-191).
local function build_output(project, path)
  local build_dir = project.buildDir
  if type(build_dir) ~= "string" then return nil end
  if path == build_dir then return { buildOutput = "." } end
  if string.sub(path, 1, #build_dir + 1) ~= build_dir .. "/" then return nil end
  return { buildOutput = string.sub(path, #build_dir + 2) }
end

local function translate_root(translation, project, path, construct)
  local marker = build_output(project, path)
  if marker ~= nil then return marker end
  local relative = within_project(translation, path)
  if relative == nil then return nil, true end
  return carried(translation, relative, construct), false
end

local function translate_roots(translation, project, set_name, kind, sources)
  local construct = "sourceSets." .. set_name .. "." .. kind
  if sources == nil or is_unrendered(sources) then
    block(translation, construct, "could not be read from the model", LAYOUT_ROW)
    return nil
  end
  if #(sources.includes or {}) > 0 or #(sources.excludes or {}) > 0 then
    block(translation, construct, "filters its files with includes or excludes, which no source"
          .. " root key can say", LAYOUT_ROW)
    return nil
  end
  local roots = {}
  for _, path in ipairs(sources.srcDirs or {}) do
    local root, outside = translate_root(translation, project, path, construct)
    if outside then
      block(translation, construct, "names the root " .. path .. ", which lies outside the project",
            LAYOUT_ROW)
      return nil
    end
    roots[#roots + 1] = root
  end
  if same_list(roots, { default_root(translation, set_name, kind) }) then return nil end
  return one_or_list(roots)
end

--- @implNote a set's classpath is its configuration plus whatever the build
--- added as files: Gradle itself adds main's output to test's, and a build may
--- add more, which no resolved artifact row shows and no key can say.
local function check_classpath_wiring(translation, set_name, set, allowed_compile, allowed_runtime)
  local checks = { { "compileClasspath", set.compileClasspathBeyond, allowed_compile },
                   { "runtimeClasspath", set.runtimeClasspathBeyond, allowed_runtime } }
  for _, check in ipairs(checks) do
    local construct = "sourceSets." .. set_name .. "." .. check[1]
    if is_unrendered(check[2]) then
      block(translation, construct, "could not be read from the model", LAYOUT_ROW)
    else
      for _, path in ipairs(check[2] or {}) do
        if not check[3][path] then
          block(translation, construct, "holds " .. path .. " beside its configuration's artifacts,"
                .. " which no key can say", LAYOUT_ROW)
        end
      end
    end
  end
end

local function union(...)
  local out = {}
  for _, set in ipairs({ ... }) do
    for key in pairs(set) do out[key] = true end
  end
  return out
end

local function copy_into(target, source)
  for key, value in pairs(source) do target[key] = value end
end

local function is_utf8(encoding)
  return encoding ~= nil and string.gsub(string.upper(encoding), "[-_]", "") == "UTF8"
end

--- The encoding the old build's javac read this set's sources in, or nil when
--- the model cannot know it.
---
--- @implNote never the dump's `jvm.*`: those describe the JDK 17 daemon that
--- ran the dump, not the JDK whose javac compiled the old build.
local function effective_encoding(project, set)
  local encoding = task_values(project, set.compileJavaTask).encoding
  if encoding ~= nil then return encoding end
  local level = tonumber(language_version(project) or "")
  if level ~= nil and level >= UTF8_BY_DEFAULT_FROM then return "UTF-8" end
  return nil
end

local function on_disk(translation, path)
  local rooted = translation.prefix .. path
  if translation.dir == nil or translation.dir == "." then return rooted end
  return translation.dir .. "/" .. rooted
end

--- The first file under `directory` holding a byte of 0x80 or above, or nil.
local function first_non_ascii_file(directory)
  for _, entry in ipairs(daukle.list(directory) or {}) do
    local path = directory .. "/" .. entry.name
    if entry.kind == "directory" then
      local found = first_non_ascii_file(path)
      if found ~= nil then return found end
    elseif entry.kind == "file" and string.find(daukle.read(path), HIGH_BYTE) ~= nil then
      return path
    end
  end
  return nil
end

--- @implNote ASCII compiles to the same bytes in any encoding javac is given,
--- so only a non-ASCII byte makes the old encoding matter (ruled 2026-10-19).
local function check_encoding(translation, project, set_name, set)
  local encoding = effective_encoding(project, set)
  if is_utf8(encoding) then return end
  for _, root in ipairs((set.java or {}).srcDirs or {}) do
    if not is_absolute(root) then
      local found = first_non_ascii_file(on_disk(translation, root))
      if found ~= nil then
        block(translation, found, "holds a byte of 0x80 or above, and the old build compiled source set "
              .. set_name .. " as " .. (encoding or "the JDK's default encoding, which the model cannot"
              .. " know below JDK 18") .. ", while daukle/gradle always compiles UTF-8", LAYOUT_ROW)
        return
      end
    end
  end
end

local function translate_set_layout(translation, project, set_name, set, keys)
  local layout = {}
  layout[keys.java] = translate_roots(translation, project, set_name, "java", set.java)
  layout[keys.resources] = translate_roots(translation, project, set_name, "resources", set.resources)
  return layout
end

local function sorted_set_names(sets)
  local names = {}
  for name in pairs(sets) do
    if name ~= MAIN and name ~= TEST then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

local TEST_TYPE = "org.gradle.api.tasks.testing.Test"
local JUNIT_PLATFORM_OPTIONS = "org.gradle.api.tasks.testing.junitplatform.JUnitPlatformOptions"

local function holds_a_script_action(task)
  for _, action in ipairs(task.actions or {}) do
    if action.script ~= nil or action.sourceFile ~= nil then return true end
  end
  return false
end

--- Whether the set's own `Test` task is the one `sourceSets.<name>.test`
--- renders, so the set translates as a test set instead of its task being
--- carried (spec D-198, 4.5).
---
--- @implNote a task holding an action is never translated: no key says
--- "run this code", and a translated registration beside a carried one is a
--- duplicate task. The comparison still checks the rest of the task's values.
local function is_translatable_test_task(project, name)
  for _, task in ipairs(project.tasks or {}) do
    if task.name == name then
      return task.type == TEST_TYPE and (task.values or {}).framework == JUNIT_PLATFORM_OPTIONS
             and not holds_a_script_action(task)
    end
  end
  return false
end

--- @param main_output the main set's output, which a test set's classpaths
--- hold as Gradle's own `test` does
local function translate_custom_set(translation, project, rows, name, set, main_output)
  local test = is_translatable_test_task(project, name)
  local seen = test and main_output or {}
  check_classpath_wiring(translation, name, set, seen, union(seen, as_set(set.output)))
  check_encoding(translation, project, name, set)
  local block_of = translate_set_layout(translation, project, name, set, { java = "sourceRoot", resources = "resourceRoot" })
  copy_into(block_of, translate_dependencies.custom(translation, project, rows, name, set))
  if test then block_of.test = true end
  return block_of
end

local function translate_source_sets(translation, project, config)
  local sets = extension_value(project, "sourceSets")
  if sets == nil or sets[MAIN] == nil then
    block(translation, "sourceSets", "could not be read from the model, so there is no main source set"
          .. " to translate", LAYOUT_ROW)
    return
  end
  local rows = translate_dependencies.rows_by_configuration(project)
  local main = sets[MAIN]
  local main_output = as_set(main.output)
  check_classpath_wiring(translation, MAIN, main, {}, main_output)
  check_encoding(translation, project, MAIN, main)
  copy_into(config, translate_set_layout(translation, project, MAIN, main, ROOT_KEYS.main))
  local main_buckets, main_split = translate_dependencies.main(translation, project, rows, main)
  copy_into(config, main_buckets)
  local test = sets[TEST]
  if test ~= nil then
    check_classpath_wiring(translation, TEST, test, main_output, union(main_output, as_set(test.output)))
    check_encoding(translation, project, TEST, test)
    copy_into(config, translate_set_layout(translation, project, TEST, test, ROOT_KEYS.test))
    copy_into(config, translate_dependencies.test(translation, project, rows, test, main_split))
  end
  for _, name in ipairs(sorted_set_names(sets)) do
    config.sourceSets = config.sourceSets or {}
    config.sourceSets[name] = translate_custom_set(translation, project, rows, name, sets[name], main_output)
  end
end

local function main_compile_task(project)
  local sets = extension_value(project, "sourceSets") or {}
  return (sets[MAIN] or {}).compileJavaTask or "compileJava"
end

--- Blocks each configuration the dump could not resolve: its rows are
--- missing from the model, so no key can reproduce it.
local function block_unresolved(translation, project)
  for _, failure in ipairs((project.dependencies or {}).errors or {}) do
    block(translation, tostring(failure.configuration), "could not be resolved in the old build: "
          .. tostring(failure.error), migrate_surface.CONFIGURATIONS_ROW)
  end
end

--- @param project  one PROJECT of the model `migrator.read_model` returns
--- @param build    what `lib/translation`'s `new` takes
--- @return { config = <the [toolchains.gradle] keys>, name = <the project's name>,
---           version = <the project's version, or nil when Gradle's is unspecified>,
---           requires = <the paths of this build's projects its main classpaths hold>,
---           requiredBuilds = <the identity paths of the included builds they hold>,
---           unpinned = <set of the components no pinned entry could name>,
---           blockers = { { construct, where, why, surface? } } }
function translate_model.project(project, build)
  local translation = translation_state.new(build)
  block_unresolved(translation, project)
  local config = {}
  config.jdk = carried(translation, language_version(project), "java.toolchain.languageVersion")
  config.release = translate_release(translation, project, main_compile_task(project))
  config.main = translate_main(translation, project)
  if tables.named(project.tasks, SOURCES_JAR_TASK) ~= nil then config.sourcesJar = true end
  translate_source_sets(translation, project, config)
  copy_into(config, translate_plugins.project(translation, project))
  local version = project.version ~= UNSPECIFIED and carried(translation, project.version, "version") or nil
  return { config = config, name = carried(translation, project.name, "rootProject.name"), version = version,
           requires = sorted_keys(translation.requires), requiredBuilds = sorted_keys(translation.required_builds),
           unpinned = translation.unpinned, blockers = translation.blockers }
end

--- A project that becomes no module: the root of a multi-project build, or a
--- parent directory Gradle made a project of. Only its plugin classpath has a
--- key, the derived root's; everything else it holds is compared with the
--- generated build's project of the same path, which holds nothing.
--- @return { config = { pluginClasspath? }, name = <the project's name>, unpinned, blockers }
function translate_model.parent(project, build)
  local translation = translation_state.new(build)
  block_unresolved(translation, project)
  if extension_value(project, "sourceSets") ~= nil then
    block(translation, project.path, "applies a Java plugin, and with modules daukle/gradle's root and parent"
          .. " projects compile nothing", LAYOUT_ROW)
  end
  return { config = translate_plugins.classpath(translation, project),
           name = carried(translation, project.name, "rootProject.name"), unpinned = translation.unpinned,
           blockers = translation.blockers }
end

--- The settings plugins of the build the model describes.
--- @param build as `translate_model.project` takes it
--- @return { config = <the settings keys>, blockers = { { construct, where, why, surface? } } }
function translate_model.settings(build)
  local translation = translation_state.new(build)
  return { config = translate_plugins.settings(translation, build.model), blockers = translation.blockers }
end

return translate_model
