--- Each task an old project and its generated counterpart both have,
--- compared by what the task's typed reader dumped, and the core
--- `application` extension, so a setting no key carries blocks rather than
--- builds differently.
---
--- @implNote paths are relative to each build's own root, so they compare as
--- they stand. The `java` extension is not compared: its toolchain is the
--- `jdk` key plus lib/migrate_old_build's toolchain blockers, and its levels
--- are `release`, compared here as each JavaCompile's effective level.
local migrate_task_values = {}

local migrate_surface = daukle.require("lib/migrate_surface")
local migrate_blockers = daukle.require("lib/migrate_blockers")
local migrate_paths = daukle.require("lib/migrate_paths")
local translation = daukle.require("lib/translation")
local tables = daukle.require("lib/tables")

local blocker = migrate_surface.blocker
local is_unrendered = translation.is_unrendered
local UNCOVERED_ROW = migrate_surface.UNCOVERED_ROW
local UNSPECIFIED = "unspecified"
local DEFAULT_LEVEL = "the JDK's own level"

local TASK_DIFFERS = "differs in the build daukle/gradle generates from the translated keys, and no key"
                     .. " carries this setting of the task"
local APPLICATION_DIFFERS = "differs in the build daukle/gradle generates from the translated keys, and no"
                            .. " key carries this setting of the application extension"
local MAIN_CLASS_ATTRIBUTE = "manifestAttributes.Main-Class"
local MAIN_CLASS_DIFFERS = "is a jar manifest attribute of the old build, and the `main` key it translates"
                           .. " to applies the application plugin, which writes none into the jar"

local function copy(values)
  local out = {}
  for key, value in pairs(values) do out[key] = value end
  return out
end

local function level_text(value)
  if type(value) == "number" then return string.format("%.0f", value) end
  if type(value) == "string" and string.sub(value, 1, 2) == "1." then return string.sub(value, 3) end
  return value
end

--- A JavaCompile's source or target level: its `release` when set, else
--- the level it was given, or DEFAULT_LEVEL when it holds the `java`
--- extension's evaluated value and the build set none there, which is the
--- toolchain's or the running JDK's and so the `jdk` key's.
local function effective_level(values, java, key)
  if values.release ~= nil and not is_unrendered(values.release) then return level_text(values.release) end
  local raw_key = "raw" .. string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
  if type(java) == "table" and java[raw_key] == nil and values[key] == java[key] then return DEFAULT_LEVEL end
  return level_text(values[key])
end

local function java_of(project)
  local java = (project.extensions or {}).java
  return java ~= nil and java.value or nil
end

--- @implNote `encoding` is left out: the generated build always compiles
--- UTF-8, and lib/translate_model blocks a non-ASCII source the old build
--- compiled otherwise.
local function compile_values(values, project)
  local out = copy(values)
  local java = java_of(project)
  out.sourceCompatibility = effective_level(values, java, "sourceCompatibility")
  out.targetCompatibility = effective_level(values, java, "targetCompatibility")
  out.release, out.encoding, out.encodingSet = nil, nil, nil
  return out
end

local function holds_a_file(directory)
  for _, entry in ipairs(daukle.list(directory) or {}) do
    if entry.kind == "file" then return true end
    if entry.kind == "directory" and holds_a_file(directory .. "/" .. entry.name) then return true end
  end
  return false
end

local function source_roots(set)
  local roots = tables.append({}, (set.java or {}).srcDirs)
  for _, other in pairs(set.others or {}) do tables.append(roots, other.srcDirs) end
  return roots
end

local function roots_hold_a_file(roots, root)
  for _, path in ipairs(roots) do
    if not migrate_paths.is_below(path) or holds_a_file(migrate_paths.within(root, path)) then return true end
  end
  return false
end

--- Whether the source set whose output holds a test task's classes has a
--- source file; true when no set can be named, so a doubt never passes.
local function tests_have_sources(classes_dirs, project, root)
  local sets = ((project.extensions or {}).sourceSets or {}).value
  if type(classes_dirs) ~= "table" or type(sets) ~= "table" or is_unrendered(sets) then return true end
  for _, set in pairs(sets) do
    local output = type(set.output) == "table" and tables.as_set(set.output) or {}
    for _, directory in ipairs(classes_dirs) do
      if output[directory] then return roots_hold_a_file(source_roots(set), root) end
    end
  end
  return true
end

--- @implNote the generated build always runs the JUnit Platform, so a test
--- task with no source to run is the same whichever framework it names.
local function reconcile_test(old, new, context)
  if old.framework ~= new.framework and not tests_have_sources(old.testClassesDirs, context.old, context.root) then
    old.framework, new.framework = nil, nil
  end
end

local function non_empty(value)
  return type(value) == "string" and value ~= ""
end

--- The file name Gradle gives an archive from its parts.
local function composed_name(values)
  local parts = {}
  for _, key in ipairs({ "archiveBaseName", "archiveAppendix", "archiveVersion", "archiveClassifier" }) do
    if non_empty(values[key]) then parts[#parts + 1] = values[key] end
  end
  local name = table.concat(parts, "-")
  if non_empty(values.archiveExtension) then name = name .. "." .. values.archiveExtension end
  return name
end

local function archive_version_of(project)
  if project.version == UNSPECIFIED then return nil end
  return project.version
end

--- @implNote a file name composed from its parts is compared as those
--- parts. Where the project's own name or version differs by design (the
--- version a migration gives an unversioned build, the name and version an
--- included build block does not carry), a part that follows it is equal.
local function reconcile_jar(old, new, context)
  if old.archiveFileName == composed_name(old) and new.archiveFileName == composed_name(new) then
    old.archiveFileName, new.archiveFileName = nil, nil
  end
  if not context.identity_follows then return end
  if old.archiveVersion == archive_version_of(context.old)
     and new.archiveVersion == archive_version_of(context.generated) then
    old.archiveVersion, new.archiveVersion = nil, nil
  end
  if old.archiveBaseName == context.old.name and new.archiveBaseName == context.generated.name then
    old.archiveBaseName, new.archiveBaseName = nil, nil
  end
end

--- @implNote Gradle's default title, `<name> <version> API`, or `<name> API`
--- for an unspecified version.
local function default_title(project)
  if project.version == UNSPECIFIED then return project.name .. " API" end
  return project.name .. " " .. tostring(project.version) .. " API"
end

local function reconcile_javadoc(old, new, context)
  if context.identity_follows and old.title == default_title(context.old)
     and new.title == default_title(context.generated) then
    old.title, new.title = nil, nil
  end
end

local RECONCILE = { test = reconcile_test, jar = reconcile_jar, javadoc = reconcile_javadoc }

--- Both sides' values, with what differs only in form made equal.
local function reconciled(task, generated_task, context)
  local old, new = copy(task.values), copy(generated_task.values)
  if task.reader == "javaCompile" then
    old, new = compile_values(old, context.old), compile_values(new, context.generated)
  end
  if RECONCILE[task.reader] ~= nil then RECONCILE[task.reader](old, new, context) end
  return old, new
end

local function is_list(value)
  return type(value) == "table" and #value > 0
end

--- Each path at which `new` differs from `old`: a map key by key, a list as a whole.
local function differences_of(old, new, path, out)
  if is_unrendered(old) or is_unrendered(new) then return out end
  if type(old) == "table" and type(new) == "table" and not is_list(old) and not is_list(new) then
    local keys = tables.as_set(tables.sorted_keys(old))
    for key in pairs(new) do keys[key] = true end
    for _, key in ipairs(tables.sorted_keys(keys)) do differences_of(old[key], new[key], path .. "." .. key, out) end
  elseif not tables.deep_equal(old, new) then
    out[#out + 1] = path
  end
  return out
end

local function why_of(difference, default)
  if string.sub(difference, -#MAIN_CLASS_ATTRIBUTE) == MAIN_CLASS_ATTRIBUTE then return MAIN_CLASS_DIFFERS end
  return default
end

local function unreadable(values, path, side, where, blockers)
  for _, found in ipairs(migrate_blockers.unrendered_paths(values, path)) do
    blockers[#blockers + 1] = blocker(found.path, where, "could not be read from " .. side .. " (" .. found.why
                                      .. "), so it cannot be compared", UNCOVERED_ROW)
  end
end

local function value_blockers(old, new, path, where, why, blockers)
  unreadable(old, path, "the old build", where, blockers)
  unreadable(new, path, "the build daukle/gradle generates", where, blockers)
  for _, difference in ipairs(differences_of(old, new, path, {})) do
    blockers[#blockers + 1] = blocker(difference, where, why_of(difference, why),
                                      UNCOVERED_ROW)
  end
end

local function task_blockers(task, generated_task, context, blockers)
  local path, where = task.path or task.name, context.where
  if task.enabled ~= generated_task.enabled then
    blockers[#blockers + 1] = blocker(path .. ".enabled", where, "is " .. tostring(task.enabled) .. " in the old"
                                      .. " build and " .. tostring(generated_task.enabled) .. " in the build"
                                      .. " daukle/gradle generates from the translated keys", UNCOVERED_ROW)
  end
  if task.reader == nil then return end
  if generated_task.reader ~= task.reader then
    blockers[#blockers + 1] = blocker(path, where, "is a " .. tostring(task.type) .. " in the old build and a "
                                      .. tostring(generated_task.type) .. " in the build daukle/gradle generates",
                                      UNCOVERED_ROW)
    return
  end
  if type(task.values) ~= "table" or type(generated_task.values) ~= "table" then
    value_blockers(task.values, generated_task.values, path, where, TASK_DIFFERS, blockers)
    return
  end
  local old, new = reconciled(task, generated_task, context)
  value_blockers(old, new, path, where, TASK_DIFFERS, blockers)
end

--- @param old       an old project of the model
--- @param generated its counterpart in the generated build's model
--- @param options   { where, root = <the old project's build root, relative to the directory migrate runs in> }
function migrate_task_values.differences(old, generated, options)
  local context = { old = old, generated = generated, where = options.where, root = options.root,
                    identity_follows = old.version ~= generated.version or old.name ~= generated.name }
  local blockers = {}
  for _, task in ipairs(old.tasks or {}) do
    local generated_task = tables.named(generated.tasks, task.name)
    if generated_task ~= nil then task_blockers(task, generated_task, context, blockers) end
  end
  return blockers
end

--- The core `application` extension: absent from the generated build, or
--- holding another value there.
function migrate_task_values.application(old, generated, where)
  local application = (old.extensions or {}).application
  if application == nil or application.core ~= true then return {} end
  local counterpart = (generated.extensions or {}).application
  if counterpart == nil then
    return { blocker("application", where, "is applied in the old build and not in the build daukle/gradle"
                     .. " generates from the translated keys, which applies it only with a `main`", UNCOVERED_ROW) }
  end
  local blockers = {}
  value_blockers(application.value, counterpart.value, "application", where, APPLICATION_DIFFERS, blockers)
  return blockers
end

return migrate_task_values
