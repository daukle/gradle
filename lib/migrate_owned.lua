--- The files a successful migration moves aside (spec section 5, "Owned"),
--- and the one directory it refuses to: `buildSrc/`.
local migrate_owned = {}

local gradle_properties = daukle.require("lib/gradle_properties")
local migrate_paths = daukle.require("lib/migrate_paths")
local migrate_surface = daukle.require("lib/migrate_surface")

local within = migrate_paths.within

local BUILD_FILES = { "settings.gradle", "settings.gradle.kts", "gradle.properties", "gradlew", "gradlew.bat" }
local GRADLE_DIRECTORY = "gradle"
local WRAPPER_DIRECTORY = "wrapper"
local CATALOG_SUFFIX = ".versions.toml"
local BUILD_SOURCE = "buildSrc"

local function add(owned, seen, path)
  if seen[path] then return end
  seen[path] = true
  owned[#owned + 1] = path
end

local function lies_under(path, directory)
  local prefix = directory .. "/"
  return path == directory or string.sub(path, 1, #prefix) == prefix
end

local function holds_a_build(directory, build_directories)
  for _, build_directory in ipairs(build_directories) do
    if lies_under(build_directory, directory) then return true end
  end
  return false
end

local function ends_with(name, suffix)
  return #name > #suffix and string.sub(name, -#suffix) == suffix
end

--- A build's `gradle/`: whole, or, when an included build lives inside it
--- (`gradle/plugins` is a common place for one), only the wrapper and the
--- version catalogs, because owning the whole directory would move that
--- build's sources aside and core refuses an owned path nested in another.
local function add_gradle_directory(owned, seen, directory, build_directories)
  local gradle = within(directory, GRADLE_DIRECTORY)
  if not migrate_paths.has_entry(directory or ".", GRADLE_DIRECTORY, "directory") then return end
  if not holds_a_build(gradle, build_directories) then
    add(owned, seen, gradle)
    return
  end
  for _, entry in ipairs(daukle.list(gradle) or {}) do
    local wrapper = entry.kind == "directory" and entry.name == WRAPPER_DIRECTORY
    local catalog = entry.kind == "file" and ends_with(entry.name, CATALOG_SUFFIX)
    if wrapper or catalog then add(owned, seen, gradle .. "/" .. entry.name) end
  end
end

local function lies_under_any(path, owned)
  for _, directory in ipairs(owned) do
    if path ~= directory and lies_under(path, directory) then return true end
  end
  return false
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

--- Each script the build applied with `apply from`, which is an old build file
--- like a build script (spec D-188, 4.7), unless a directory already owned holds it.
local function add_applied_scripts(owned, seen, directory, model)
  for _, path in ipairs(sorted_keys(model.appliedScripts)) do
    local applied = within(directory, path)
    if migrate_paths.is_below(path) and not lies_under_any(applied, owned) then add(owned, seen, applied) end
  end
end

--- One build's files: each project's build file, each script it applied, and
--- what sits at the build's root.
local function add_build(owned, seen, directory, model, build_directories)
  for _, project in ipairs(model.projects or {}) do
    if migrate_paths.is_below(project.buildFile) then add(owned, seen, within(directory, project.buildFile)) end
  end
  local listed = directory or "."
  for _, name in ipairs(BUILD_FILES) do
    if migrate_paths.has_file(listed, name) then add(owned, seen, within(directory, name)) end
  end
  add_gradle_directory(owned, seen, directory, build_directories)
  add_applied_scripts(owned, seen, directory, model)
end

--- Each included build with a model, as { directory, model }, its directory
--- relative to the migration's.
local function included_builds(context, model, included_models)
  local builds = {}
  for _, entry in ipairs(model.includedBuilds or {}) do
    local included = included_models[entry.name]
    if included ~= nil and migrate_paths.is_below(entry.dir) then
      builds[#builds + 1] = { directory = within(context.dir, entry.dir), model = included }
    end
  end
  return builds
end

--- Every included build's directory relative to the migration's, a build
--- with no model included.
local function build_directories_of(context, model)
  local directories = {}
  for _, entry in ipairs(model.includedBuilds or {}) do
    if migrate_paths.is_below(entry.dir) then directories[#directories + 1] = within(context.dir, entry.dir) end
  end
  return directories
end

--- @param model           the old root build's model
--- @param included_models the included builds' models, by the name `includedBuilds` gives them
--- @return the owned paths, relative to the directory migrate runs in
function migrate_owned.paths(context, model, included_models)
  local owned, seen = {}, {}
  local build_directories = build_directories_of(context, model)
  add_build(owned, seen, context.dir, model, build_directories)
  for _, build in ipairs(included_builds(context, model, included_models)) do
    add_build(owned, seen, build.directory, build.model, build_directories)
  end
  return owned
end

local GRADLE_PROPERTIES = "gradle.properties"

--- The `gradle.properties` keys that change how Gradle runs and never what a
--- build produces: the daemon's JVM, the daemon itself, parallel and
--- on-demand configuration, the build cache, the console, logging,
--- warnings, the worker count and file-system watching. A root build's
--- project property is carried as `gradleProperties`; any other Gradle setting
--- has an effect on the build, and the file is removed after the proof, so it
--- blocks, as does every key of an included build's file.
local INERT_PROPERTIES = {
  ["org.gradle.jvmargs"] = true,
  ["org.gradle.daemon"] = true,
  ["org.gradle.parallel"] = true,
  ["org.gradle.caching"] = true,
  ["org.gradle.configureondemand"] = true,
  ["org.gradle.console"] = true,
  ["org.gradle.logging.level"] = true,
  ["org.gradle.warning.mode"] = true,
  ["org.gradle.workers.max"] = true,
  ["org.gradle.vfs.watch"] = true,
}

--- Whether a key is carried as `gradleProperties` when its file is the root build's.
local function is_carried_property(key, is_root)
  return is_root and not gradle_properties.is_gradle_setting(key)
end

--- Why one entry of a build's `gradle.properties` blocks, or nil when it is
--- dropped as inert or carried as `gradleProperties`.
local function property_problem(entry, is_root)
  if INERT_PROPERTIES[entry.key] then return nil end
  if not is_carried_property(entry.key, is_root) then
    return "is a property no daukle/gradle key carries, and the file is removed after the proof"
  end
  if not gradle_properties.is_portable(entry.value) then return string.sub(gradle_properties.NOT_PORTABLE, 2) end
  return nil
end

local function property_blockers(directory, blockers, is_root)
  if not migrate_paths.has_file(directory, GRADLE_PROPERTIES) then return end
  local where = within(directory, GRADLE_PROPERTIES)
  for _, entry in ipairs(gradle_properties.parse(daukle.read(where))) do
    local why = property_problem(entry, is_root)
    if why ~= nil then
      blockers[#blockers + 1] = migrate_surface.blocker(entry.key, where, why, migrate_surface.UNCOVERED_ROW)
    end
  end
end

--- The root build's project properties as the `gradleProperties` value, or nil.
function migrate_owned.root_properties(context)
  local directory = context.dir or "."
  if not migrate_paths.has_file(directory, GRADLE_PROPERTIES) then return nil end
  local carried = {}
  for _, entry in ipairs(gradle_properties.parse(daukle.read(within(directory, GRADLE_PROPERTIES)))) do
    if is_carried_property(entry.key, true) and gradle_properties.is_portable(entry.value) then
      carried[entry.key] = entry.value
    end
  end
  if next(carried) == nil then return nil end
  return carried
end

--- A `buildSrc/` in the root build or an included one: Gradle compiles it
--- before the build and puts it on every build script's classpath, and no
--- dumped value says what it did, so it can be neither translated nor removed.
--- And each `gradle.properties` key outside INERT_PROPERTIES that `gradleProperties` does not carry.
function migrate_owned.blockers(context, model, included_models)
  local directories = { context.dir or "." }
  for _, build in ipairs(included_builds(context, model, included_models)) do
    directories[#directories + 1] = build.directory
  end
  local blockers = {}
  for index, directory in ipairs(directories) do
    property_blockers(directory, blockers, index == 1)
    if migrate_paths.has_entry(directory, BUILD_SOURCE, "directory") then
      blockers[#blockers + 1] = migrate_surface.blocker(BUILD_SOURCE, within(directory, BUILD_SOURCE),
                                                        "is build logic Gradle compiles before the build, and the"
                                                        .. " migration cannot show that every effect it has was"
                                                        .. " translated, so it is neither carried over nor removed",
                                                        migrate_surface.BOUNDARY_ROW)
    end
  end
  return blockers
end

return migrate_owned
