--- The files a successful migration moves aside (spec section 5, "Owned"),
--- and the one directory it refuses to: `buildSrc/`.
local migrate_owned = {}

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

local GRADLE_PROPERTIES = "gradle.properties"

--- The `gradle.properties` keys that change how Gradle runs and never what a
--- build produces: the daemon's JVM, the daemon itself, parallel and
--- on-demand configuration, the build cache, the console, logging,
--- warnings, the worker count and file-system watching. Any other key is a
--- project property the build may read, or a Gradle setting with an effect
--- on the build, and the file is removed after the proof, so it blocks.
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

local function is_continued(line)
  local backslashes = string.match(line, "(\\*)$")
  return #backslashes % 2 == 1
end

--- The key of one logical properties line: up to the first unescaped `=`,
--- `:` or blank, with its escapes undone.
local function property_key(line)
  local key, index = {}, 1
  while index <= #line do
    local character = string.sub(line, index, index)
    if character == "\\" then
      index = index + 1
      key[#key + 1] = string.sub(line, index, index)
    elseif character == "=" or character == ":" or string.match(character, "%s") then
      break
    else
      key[#key + 1] = character
    end
    index = index + 1
  end
  return table.concat(key)
end

--- The keys a properties file sets, in file order.
function migrate_owned.property_keys(text)
  local keys, continued = {}, false
  for raw in string.gmatch(text .. "\n", "([^\n]*)\n") do
    local line = string.gsub(string.gsub(raw, "\r$", ""), "^%s+", "")
    local starts = not continued and line ~= "" and not string.match(line, "^[#!]")
    if starts then keys[#keys + 1] = property_key(line) end
    continued = (continued or starts) and is_continued(line)
  end
  return keys
end

local function property_blockers(directory, blockers)
  if not migrate_paths.has_file(directory, GRADLE_PROPERTIES) then return end
  local where = within(directory, GRADLE_PROPERTIES)
  for _, key in ipairs(migrate_owned.property_keys(daukle.read(where))) do
    if not INERT_PROPERTIES[key] then
      blockers[#blockers + 1] = migrate_surface.blocker(key, where, "is a property no daukle/gradle key carries,"
                                                        .. " and the file is removed after the proof",
                                                        migrate_surface.UNCOVERED_ROW)
    end
  end
end

--- A `buildSrc/` in the root build or an included one: Gradle compiles it
--- before the build and puts it on every build script's classpath, and no
--- dumped value says what it did, so it can be neither translated nor removed.
--- And each `gradle.properties` key outside INERT_PROPERTIES.
function migrate_owned.blockers(context, model, included_models)
  local directories = { context.dir or "." }
  for _, build in ipairs(included_builds(context, model, included_models)) do
    directories[#directories + 1] = build.directory
  end
  local blockers = {}
  for _, directory in ipairs(directories) do
    property_blockers(directory, blockers)
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
