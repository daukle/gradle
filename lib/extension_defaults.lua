--- What each third-party extension holds in a build that applies the same
--- plugins and sets nothing: the generated build rendered without `configure`
--- and dumped, so a translation can carry only what the old script changed.
---
--- @implNote a dump cannot tell a value a script set from one its plugin set
--- (spec 2026-10-30-gradle-extension-defaults-design.md), and the walk reads
--- a plugin's whole internal model as values; this second build is the only
--- way to tell them apart. Its paths are the derived tree's, so they are read
--- as the comparison reads them (`migrate_real_tree.generated`), and a source
--- directory the generated build adds again from the real tree
--- (`source_sets.conventional_roots`) is dropped as the duplicate it then is.
local extension_defaults = {}

local migrate_real_tree = daukle.require("lib/migrate_real_tree")

--- Passed in place of defaults to translate without any `configure`: the
--- build the defaults are dumped from.
extension_defaults.SKIP = { skip = true }

local ROOT = "root"

local function deduplicated(list)
  local seen, out = {}, {}
  for _, item in ipairs(list) do
    if not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  return out
end

local function without_repeated_directories(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do
    if key == "srcDirs" and type(item) == "table" then
      out[key] = deduplicated(item)
    else
      out[key] = without_repeated_directories(item)
    end
  end
  return out
end

local function by_path(model)
  local projects = {}
  for _, project in ipairs(model.projects or {}) do projects[project.path] = project.extensions or {} end
  return { projects = projects, settings = model.settingsExtensions or {} }
end

local function read(model, real_root, modules)
  local mapped = migrate_real_tree.generated(model, model.rootDir, real_root, modules)
  return by_path(without_repeated_directories(mapped))
end

--- @param generated        the defaults build's model
--- @param generated_models each included build's, by directory, as `{ model }`
--- @param real_roots       the old build's root, and each included build's by directory
--- @param modules          the module names of the build
function extension_defaults.read(generated, generated_models, real_roots, modules)
  local builds = { [ROOT] = read(generated, real_roots[ROOT], modules) }
  for dir, entry in pairs(generated_models or {}) do
    if real_roots[dir] ~= nil then builds[dir] = read(entry.model, real_roots[dir], {}) end
  end
  return { builds = builds }
end

local function build_of(defaults, build)
  if defaults == nil or defaults == extension_defaults.SKIP then return nil end
  return defaults.builds[build or ROOT]
end

--- One project's extensions in the defaults build, SKIP, or nil when there is
--- nothing to subtract (no defaults build, or a project it lacks).
--- @param build an included build's directory, or nil for the root build
function extension_defaults.project(defaults, build, path)
  if defaults == extension_defaults.SKIP then return defaults end
  local found = build_of(defaults, build)
  return found ~= nil and found.projects[path] or nil
end

--- A build's settings extensions in the defaults build, as `project` returns them.
function extension_defaults.settings(defaults, build)
  if defaults == extension_defaults.SKIP then return defaults end
  local found = build_of(defaults, build)
  return found ~= nil and found.settings or nil
end

return extension_defaults
