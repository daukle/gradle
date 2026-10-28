--- The version catalogs a `catalogs` key declares for carried code to read,
--- and the settings block that registers them.
local catalogs = {}

local module_graph = daukle.require("lib/modules")
local groovy = daukle.require("lib/groovy")

local CONVENTION_CATALOG_NAME = "daukleConventionCatalog"
local STAND_IN_DIRECTORY = "build/"

--- The directory an instance's catalogs live in, below its committed `daukle/<instance>/`.
function catalogs.directory_of(instance)
  return "daukle/" .. instance .. "/catalogs/"
end

local function starts_with(text, prefix)
  return string.sub(text, 1, #prefix) == prefix
end

local function ends_with(text, suffix)
  return string.sub(text, -#suffix) == suffix
end

local function is_catalog_path(path, directory)
  return starts_with(path, directory) and ends_with(path, ".toml")
         and module_graph.problem_of(string.sub(path, #directory + 1)) == nil
end

local function path_problem(label, name, path, instance)
  local directory = catalogs.directory_of(instance)
  local wanted = '"' .. label .. '.' .. name .. '" must name a file under "' .. directory
                 .. '" ending ".toml"'
  if type(path) ~= "string" or path == "" then
    return wanted .. ", not " .. (path == "" and "an empty string" or "a " .. type(path))
  end
  if not is_catalog_path(path, directory) then return wanted .. ', not "' .. path .. '"' end
  return nil
end

local function name_problem(label, name)
  if type(name) == "string" and string.match(name, "^[%a_][%w_]*$") ~= nil then return nil end
  return '"' .. label .. '" names the catalog "' .. tostring(name) .. '", which is not an identifier'
end

local function sorted_names(declared)
  local names = {}
  for name in pairs(declared) do names[#names + 1] = name end
  table.sort(names, function(left, right) return tostring(left) < tostring(right) end)
  return names
end

--- @param carries_logic whether the build the key sits in sets `logic`
--- @return a list of { name, path } in name order, empty when `value` is nil
function catalogs.checked(value, label, instance, carries_logic)
  if value == nil then return {} end
  if type(value) ~= "table" then
    error('"' .. label .. '" must be a table of catalog name to file path, not a ' .. type(value), 0)
  end
  if not carries_logic then
    error('"' .. label .. '" serves carried code and nothing else: set "logic" beside it, or'
          .. ' remove it', 0)
  end
  local entries = {}
  for _, name in ipairs(sorted_names(value)) do
    local problem = name_problem(label, name) or path_problem(label, name, value[name], instance)
    if problem ~= nil then error(problem, 0) end
    entries[#entries + 1] = { name = name, path = value[name] }
  end
  return entries
end

--- Where a derived root holds a catalog the migrator renders before core has written it.
---
--- @implNote under the derived root's `build/`, which no root link takes, so
--- the write never reaches the user's own files.
function catalogs.stand_in_of(path)
  return STAND_IN_DIRECTORY .. path
end

--- Each catalog `carried_texts` stands in for, as { path below the derived root, text }.
function catalogs.stand_ins(entries, carried_texts)
  local files = {}
  for _, entry in ipairs(entries) do
    local text = carried_texts ~= nil and carried_texts[entry.path] or nil
    if text ~= nil then files[#files + 1] = { path = catalogs.stand_in_of(entry.path), text = text } end
  end
  return files
end

--- @implNote `defaultLibrariesExtensionName` keeps Gradle from registering the
--- conventional `gradle/libs.versions.toml` as `libs` a second time while the
--- real file is still linked into the derived root, which fails on both majors
--- with "you can only call the 'from' method a single time" (measured on 7.6.4
--- and 9.6.0, D-190). The file then reads as a catalog of this reserved name.
--- @param entries the list `checked` returns
--- @param climb what turns a path under the instance's real root into one from the derived root
--- @param carried_texts path -> text standing in for catalogs core has not written yet, or nil
function catalogs.settings_lines(entries, climb, carried_texts)
  if #entries == 0 then return {} end
  local lines = {
    "dependencyResolutionManagement {",
    "  defaultLibrariesExtensionName = " .. groovy.quoted(CONVENTION_CATALOG_NAME),
    "  versionCatalogs {",
  }
  for _, entry in ipairs(entries) do
    local location = climb .. entry.path
    if carried_texts ~= nil and carried_texts[entry.path] ~= nil then location = catalogs.stand_in_of(entry.path) end
    lines[#lines + 1] = "    " .. entry.name .. " { from(files(" .. groovy.quoted(location) .. ")) }"
  end
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return lines
end

return catalogs
