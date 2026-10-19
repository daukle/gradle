--- One Gradle project of the dumped model, translated into `[toolchains.gradle]`
--- keys, with every dependency pinned and a blocker for whatever the keys
--- cannot say.
---
--- @implNote dependencies are translated from the RESOLVED classpaths, not the
--- declarations, because `daukle/gradle` hands Gradle files and resolves
--- nothing: every transitive artifact has to be pinned, and a configuration
--- the build wired with `extendsFrom` shows up as the artifacts it brought.
--- The declarations decide only `api` and `compileOnlyApi`, which no resolved
--- classpath can tell from `implementation` and `compileOnly`.

local translate_model = {}

local model_dump = daukle.require("lib/model_dump")

local SURFACE = "GRADLE-SURFACE.md: "
local LAYOUT_ROW = SURFACE .. "3. The `java` extension and source layout"
local CONFIGURATIONS_ROW = SURFACE .. "2. Dependency configurations"

local MAIN = "main"
local TEST = "test"
local SOURCES_JAR_TASK = "sourcesJar"
local JAR_TASK = "jar"
local UNSPECIFIED = "unspecified"
local PLUGIN_REPOSITORY_PREFIX = "__plugin_repository__"
local SNAPSHOT_SUFFIX = "-SNAPSHOT"
local HIGH_BYTE = "[\128-\255]"

--- @implNote JEP 400: javac reads sources as UTF-8 by default from JDK 18 on.
local UTF8_BY_DEFAULT_FROM = 18

local ROOT_KEYS = {
  main = { java = "sourceRoot", resources = "resourceRoot" },
  test = { java = "testSourceRoot", resources = "testResourceRoot" },
}

local function block(translation, construct, why, surface)
  local key = construct .. "\0" .. why
  if translation.blocked[key] then return end
  translation.blocked[key] = true
  translation.blockers[#translation.blockers + 1] = { construct = construct, where = translation.where,
                                                       why = why, surface = surface }
end

local function environment_index(model)
  local index = {}
  for _, match in ipairs(model.environmentMatches or {}) do index[match.value] = match.names end
  return index
end

--- The model value, or nil with a blocker when it holds an environment
--- variable's value at dump time, whole or inside it.
---
--- @implNote a build that reads a secret at configuration time evaluates it to
--- a plain string, so the value itself is the only signal the model has, and a
--- value that passes this gate is written into a committed daukle.toml.
local function carried(translation, value, construct)
  if type(value) ~= "string" then return value end
  local names = translation.environment[value]
  if names == nil then return value end
  block(translation, construct, "holds the value of the environment variable "
        .. table.concat(names, ", ") .. ", and writing it would commit what may be a secret into"
        .. " daukle.toml")
  return nil
end

local function is_unrendered(value)
  return type(value) == "table" and value["$unrendered"] ~= nil
end

local function extension_value(project, name)
  local extension = (project.extensions or {})[name]
  if extension == nil or is_unrendered(extension.value) then return nil end
  return extension.value
end

local function task_named(project, name)
  for _, task in ipairs(project.tasks or {}) do
    if task.name == name then return task end
  end
  return nil
end

local function task_values(project, name)
  local task = task_named(project, name)
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

--- A model path (relative to the build's root) relative to the project instead,
--- or nil when it lies outside the project.
local function within_project(project, path)
  if is_absolute(path) or path == ".." or string.sub(path, 1, 3) == "../" then return nil end
  if project.dir == "." then return path end
  local prefix = project.dir .. "/"
  if string.sub(path, 1, #prefix) ~= prefix then return nil end
  return string.sub(path, #prefix + 1)
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
    local relative = within_project(project, path)
    if relative == nil then
      block(translation, construct, "names the root " .. path .. ", which lies outside the project",
            LAYOUT_ROW)
      return nil
    end
    roots[#roots + 1] = carried(translation, relative, construct)
  end
  if same_list(roots, { "src/" .. set_name .. "/" .. kind }) then return nil end
  return one_or_list(roots)
end

local function as_set(list)
  local set = {}
  for _, item in ipairs(list or {}) do set[item] = true end
  return set
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

local function repository_named(translation, project, name)
  if name == nil then return nil end
  local list, wanted = project.repositories or {}, name
  if string.sub(name, 1, #PLUGIN_REPOSITORY_PREFIX) == PLUGIN_REPOSITORY_PREFIX then
    list, wanted = translation.model.pluginManagementRepositories or {}, string.sub(name, #PLUGIN_REPOSITORY_PREFIX + 1)
  end
  for _, repository in ipairs(list) do
    if repository.name == wanted then return repository end
  end
  return nil
end

local function with_trailing_slash(url)
  if string.sub(url, -1) == "/" then return url end
  return url .. "/"
end

local function maven_path(row)
  return (string.gsub(row.group, "%.", "/")) .. "/" .. row.module .. "/" .. row.version .. "/" .. row.fileName
end

--- Why a resolved row cannot be pinned, or nil when it can.
local function unpinnable(row, repository)
  if row.kind == "project" then
    return "is a dependency on another project, which this migrator does not translate yet"
  end
  if row.kind ~= "module" then
    return "has no repository: a files(), flatDir or gradleApi() dependency, which no pinned entry can name"
  end
  if row.sha256 == nil then return "resolved to no file, so there is nothing to pin" end
  if string.sub(row.version, -#SNAPSHOT_SUFFIX) == SNAPSHOT_SUFFIX then
    return "is a snapshot, which a pinned url and digest cannot follow"
  end
  if repository == nil or repository.url == nil then
    return "resolved from a repository the model names no url for"
  end
  if repository.kind ~= "maven" then
    return "resolved from " .. repository.name .. ", which is not a Maven layout"
  end
  if string.sub(repository.url, 1, 5) == "file:" then
    return "resolved from " .. repository.name .. ", a file: repository that exists on this machine only"
  end
  return nil
end

--- The pinned entry for a resolved artifact, in the form `maven:resolve` writes
--- and `daukle/gradle` reads: the repository url plus the Maven layout path,
--- the sha256 of Gradle's cached file, and `as = "<artifact> <version>"`.
local function pin_of(translation, project, row)
  local repository = repository_named(translation, project, row.repository)
  local why = unpinnable(row, repository)
  if why ~= nil then
    block(translation, row.component, why, CONFIGURATIONS_ROW)
    return nil
  end
  local parts = { repository.url, row.group, row.module, row.version, row.fileName }
  for _, part in ipairs(parts) do
    if carried(translation, part, row.component) == nil then return nil end
  end
  return { url = with_trailing_slash(repository.url) .. maven_path(row), sha256 = row.sha256,
           as = row.module .. " " .. row.version }
end

local function row_key(row)
  return row.component .. "\0" .. (row.fileName or "")
end

--- The resolved rows of each configuration, in Gradle's classpath order.
local function rows_by_configuration(project)
  local rows = {}
  local dependencies = project.dependencies or {}
  for _, row in ipairs(dependencies.resolved or {}) do
    local list = rows[row.configuration]
    if list == nil then
      list = { seen = {} }
      rows[row.configuration] = list
    end
    if not list.seen[row_key(row)] then
      list.seen[row_key(row)] = true
      list[#list + 1] = row
    end
  end
  return rows
end

local function declared_modules(project, configuration)
  local modules = {}
  for _, row in ipairs((project.dependencies or {}).declared or {}) do
    if row.configuration == configuration and row.kind == "module" then
      modules[row.group .. ":" .. row.name] = true
    end
  end
  return modules
end

--- Each artifact a set's classpaths resolve to, sorted into the bucket that
--- reproduces them: on both compile and runtime, compile only, runtime only.
--- `inherited` maps each bucket to the artifacts the set already sees through
--- main, which are left out of it.
local function split_classpaths(rows, set, inherited)
  local compile = rows[set.compileClasspath] or { seen = {} }
  local runtime = rows[set.runtimeClasspath] or { seen = {} }
  local split = { both = {}, compile = {}, runtime = {}, processor = {} }
  for _, row in ipairs(compile) do
    local bucket = runtime.seen[row_key(row)] and "both" or "compile"
    if not inherited[bucket][row_key(row)] then split[bucket][#split[bucket] + 1] = row end
  end
  for _, row in ipairs(runtime) do
    if not compile.seen[row_key(row)] and not inherited.runtime[row_key(row)] then
      split.runtime[#split.runtime + 1] = row
    end
  end
  for _, row in ipairs(rows[set.annotationProcessor] or {}) do split.processor[#split.processor + 1] = row end
  return split
end

local function keys_of(rows)
  local keys = {}
  for _, row in ipairs(rows) do keys[row_key(row)] = true end
  return keys
end

local function append_pin(translation, project, buckets, key, row)
  local pin = pin_of(translation, project, row)
  if pin == nil then return end
  buckets[key] = buckets[key] or {}
  buckets[key][#buckets[key] + 1] = pin
end

local function is_declared_in(modules, row)
  return row.group ~= nil and modules[row.group .. ":" .. row.module] == true
end

local NOTHING_INHERITED = { both = {}, compile = {}, runtime = {} }

--- @return the buckets keyed by manifest key, and main's rows by bucket for test to inherit
local function main_dependencies(translation, project, rows, set)
  local split = split_classpaths(rows, set, NOTHING_INHERITED)
  local api = declared_modules(project, "api")
  local compile_only_api = declared_modules(project, "compileOnlyApi")
  local buckets = {}
  for _, row in ipairs(split.both) do
    append_pin(translation, project, buckets, is_declared_in(api, row) and "api" or "classpath", row)
  end
  for _, row in ipairs(split.compile) do
    append_pin(translation, project, buckets,
               is_declared_in(compile_only_api, row) and "compileOnlyApi" or "compileOnly", row)
  end
  for _, row in ipairs(split.runtime) do append_pin(translation, project, buckets, "runtimeOnly", row) end
  for _, row in ipairs(split.processor) do append_pin(translation, project, buckets, "annotationProcessor", row) end
  return buckets, split
end

--- @implNote test sees main's `implementation` and `api` on both classpaths and
--- main's `runtimeOnly` at runtime, so those are not repeated in test's keys.
--- The launcher the dump resolved for a JUnit Platform engine goes to
--- `testRuntimeOnly`, where Gradle 8 put it at test time.
local function test_dependencies(translation, project, rows, set, main_split)
  local both = keys_of(main_split.both)
  local inherited = { both = both, compile = both, runtime = union(both, keys_of(main_split.runtime)) }
  local split = split_classpaths(rows, set, inherited)
  local buckets = {}
  local keys = { both = "testClasspath", compile = "testCompileOnly", runtime = "testRuntimeOnly",
                 processor = "testAnnotationProcessor" }
  for bucket, key in pairs(keys) do
    for _, row in ipairs(split[bucket]) do append_pin(translation, project, buckets, key, row) end
  end
  for _, row in ipairs(rows[model_dump.IMPLIED_LAUNCHER] or {}) do
    append_pin(translation, project, buckets, "testRuntimeOnly", row)
  end
  return buckets
end

local function custom_dependencies(translation, project, rows, set)
  local split = split_classpaths(rows, set, NOTHING_INHERITED)
  local buckets = {}
  local keys = { both = "classpath", compile = "compileOnly", runtime = "runtimeOnly",
                 processor = "annotationProcessor" }
  for bucket, key in pairs(keys) do
    for _, row in ipairs(split[bucket]) do append_pin(translation, project, buckets, key, row) end
  end
  return buckets
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
  if translation.dir == nil or translation.dir == "." then return path end
  return translation.dir .. "/" .. path
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

local function translate_custom_set(translation, project, rows, name, set)
  check_classpath_wiring(translation, name, set, {}, as_set(set.output))
  check_encoding(translation, project, name, set)
  local block_of = translate_set_layout(translation, project, name, set,
                                        { java = "sourceRoot", resources = "resourceRoot" })
  copy_into(block_of, custom_dependencies(translation, project, rows, set))
  return block_of
end

local function translate_source_sets(translation, project, config)
  local sets = extension_value(project, "sourceSets")
  if sets == nil or sets[MAIN] == nil then
    block(translation, "sourceSets", "could not be read from the model, so there is no main source set"
          .. " to translate", LAYOUT_ROW)
    return
  end
  local rows = rows_by_configuration(project)
  local main = sets[MAIN]
  local main_output = as_set(main.output)
  check_classpath_wiring(translation, MAIN, main, {}, main_output)
  check_encoding(translation, project, MAIN, main)
  copy_into(config, translate_set_layout(translation, project, MAIN, main, ROOT_KEYS.main))
  local main_buckets, main_split = main_dependencies(translation, project, rows, main)
  copy_into(config, main_buckets)
  local test = sets[TEST]
  if test ~= nil then
    check_classpath_wiring(translation, TEST, test, main_output, union(main_output, as_set(test.output)))
    check_encoding(translation, project, TEST, test)
    copy_into(config, translate_set_layout(translation, project, TEST, test, ROOT_KEYS.test))
    copy_into(config, test_dependencies(translation, project, rows, test, main_split))
  end
  for _, name in ipairs(sorted_set_names(sets)) do
    config.sourceSets = config.sourceSets or {}
    config.sourceSets[name] = translate_custom_set(translation, project, rows, name, sets[name])
  end
end

local function main_compile_task(project)
  local sets = extension_value(project, "sourceSets") or {}
  return (sets[MAIN] or {}).compileJavaTask or "compileJava"
end

--- @param project  one PROJECT of the model `migrator.read_model` returns
--- @param build    { model = <that whole model>, dir = <context.dir>, where = <the path blockers name> }
--- @return { config = <the [toolchains.gradle] keys>, name = <the project's name>,
---           version = <the project's version, or nil when Gradle's is unspecified>,
---           blockers = { { construct, where, why, surface? } } }
function translate_model.project(project, build)
  local translation = { model = build.model, dir = build.dir, where = build.where, blockers = {}, blocked = {},
                        environment = environment_index(build.model) }
  local config = {}
  config.jdk = carried(translation, language_version(project), "java.toolchain.languageVersion")
  config.release = translate_release(translation, project, main_compile_task(project))
  config.main = translate_main(translation, project)
  if task_named(project, SOURCES_JAR_TASK) ~= nil then config.sourcesJar = true end
  translate_source_sets(translation, project, config)
  local version = project.version ~= UNSPECIFIED and carried(translation, project.version, "version") or nil
  return { config = config, name = carried(translation, project.name, "rootProject.name"), version = version,
           blockers = translation.blockers }
end

return translate_model
