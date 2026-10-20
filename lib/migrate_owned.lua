--- The files a successful migration moves aside (spec section 5, "Owned"),
--- and the one directory it refuses to: `buildSrc/`.
local migrate_owned = {}

local migrate_paths = daukle.require("lib/migrate_paths")

local within = migrate_paths.within

local BUILD_FILES = { "settings.gradle", "settings.gradle.kts", "gradle.properties", "gradlew", "gradlew.bat" }
local GRADLE_DIRECTORY = "gradle"
local WRAPPER_DIRECTORY = "wrapper"
local CATALOG_SUFFIX = ".versions.toml"
local BUILD_SOURCE = "buildSrc"
local BOUNDARY_ROW = 'GRADLE-SURFACE.md: The boundary: what "100% of Gradle" does not include'

local function add(owned, seen, path)
  if seen[path] then return end
  seen[path] = true
  owned[#owned + 1] = path
end

local function lies_under(path, directory)
  local prefix = directory .. "/"
  return string.sub(path, 1, #prefix) == prefix
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

--- One build's files: each project's build file, and what sits at the build's root.
local function add_build(owned, seen, directory, model, build_directories)
  for _, project in ipairs(model.projects or {}) do
    if migrate_paths.is_below(project.buildFile) then add(owned, seen, within(directory, project.buildFile)) end
  end
  local listed = directory or "."
  for _, name in ipairs(BUILD_FILES) do
    if migrate_paths.has_file(listed, name) then add(owned, seen, within(directory, name)) end
  end
  add_gradle_directory(owned, seen, directory, build_directories)
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

--- A `buildSrc/` in the root build or an included one: Gradle compiles it
--- before the build and puts it on every build script's classpath, and no
--- dumped value says what it did, so it can be neither translated nor removed.
function migrate_owned.blockers(context, model, included_models)
  local directories = { context.dir or "." }
  for _, build in ipairs(included_builds(context, model, included_models)) do
    directories[#directories + 1] = build.directory
  end
  local blockers = {}
  for _, directory in ipairs(directories) do
    if migrate_paths.has_entry(directory, BUILD_SOURCE, "directory") then
      blockers[#blockers + 1] = { construct = BUILD_SOURCE, where = within(directory, BUILD_SOURCE),
                                  surface = BOUNDARY_ROW,
                                  why = "is build logic Gradle compiles before the build, and the migration"
                                        .. " cannot show that every effect it has was translated, so it is"
                                        .. " neither carried over nor removed" }
    end
  end
  return blockers
end

return migrate_owned
