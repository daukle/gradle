--- The files a successful migration moves aside (spec section 5, "Owned"),
--- and the one directory it refuses to: `buildSrc/`.
local migrate_owned = {}

local migrate_paths = daukle.require("lib/migrate_paths")

local within = migrate_paths.within

local BUILD_FILES = { "settings.gradle", "settings.gradle.kts", "gradle.properties", "gradlew", "gradlew.bat" }
local WRAPPER_DIRECTORY = "gradle"
local BUILD_SOURCE = "buildSrc"
local BOUNDARY_ROW = 'GRADLE-SURFACE.md: The boundary: what "100% of Gradle" does not include'

local function add(owned, seen, path)
  if seen[path] then return end
  seen[path] = true
  owned[#owned + 1] = path
end

--- One build's files: each project's build file, and what sits at the build's root.
local function add_build(owned, seen, directory, model)
  for _, project in ipairs(model.projects or {}) do
    if migrate_paths.is_below(project.buildFile) then add(owned, seen, within(directory, project.buildFile)) end
  end
  local listed = directory or "."
  for _, name in ipairs(BUILD_FILES) do
    if migrate_paths.has_file(listed, name) then add(owned, seen, within(directory, name)) end
  end
  if migrate_paths.has_entry(listed, WRAPPER_DIRECTORY, "directory") then
    add(owned, seen, within(directory, WRAPPER_DIRECTORY))
  end
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

--- @param model           the old root build's model
--- @param included_models the included builds' models, by the name `includedBuilds` gives them
--- @return the owned paths, relative to the directory migrate runs in
function migrate_owned.paths(context, model, included_models)
  local owned, seen = {}, {}
  add_build(owned, seen, context.dir, model)
  for _, build in ipairs(included_builds(context, model, included_models)) do
    add_build(owned, seen, build.directory, build.model)
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
