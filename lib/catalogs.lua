--- The version catalogs a `catalogs` key declares for carried code to read,
--- in Gradle's own catalog shape, the `.versions.toml` each is generated as,
--- and the settings block that registers them (spec D-198, 4.4).
local catalogs = {}

local groovy = daukle.require("lib/groovy")
local tables = daukle.require("lib/tables")

local sorted_keys = tables.sorted_keys

local CONVENTION_CATALOG_NAME = "daukleConventionCatalog"
local DIRECTORY = "build/catalogs/"
local SECTIONS = { "versions", "libraries", "bundles", "plugins" }
local RICH_MEMBERS = { "require", "strictly", "prefer", "reject", "rejectAll" }
local LIBRARY_MEMBERS = { module = true, group = true, name = true, version = true }
local PLUGIN_MEMBERS = { id = true, version = true }

local function refuse(message)
  error(message, 0)
end

--- Groovy's keywords, which settings.gradle cannot take as a catalog's name.
local GROOVY_KEYWORDS = {}
for keyword in string.gmatch("abstract as assert boolean break byte case catch char class const continue def"
                             .. " default do double else enum extends false final finally float for goto if"
                             .. " implements import in instanceof int interface long native new null package"
                             .. " private protected public return short static strictfp super switch"
                             .. " synchronized this threadsafe throw throws trait transient true try var void"
                             .. " volatile while", "%S+") do
  GROOVY_KEYWORDS[keyword] = true
end

local function is_identifier(name)
  return type(name) == "string" and string.match(name, "^[%a_][%w_]*$") ~= nil and not GROOVY_KEYWORDS[name]
         and name ~= CONVENTION_CATALOG_NAME
end

local function is_list(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count == #value
end

local function is_string_list(value)
  if not is_list(value) then return false end
  for _, item in ipairs(value) do
    if type(item) ~= "string" then return false end
  end
  return true
end

local function refuse_unknown_members(value, label, allowed, what)
  for _, member in ipairs(sorted_keys(value)) do
    if not allowed[member] then
      refuse('"' .. label .. "." .. tostring(member) .. '" is not a member ' .. what .. " takes")
    end
  end
end

local function checked_rich_version(value, label)
  if next(value) == nil then refuse('"' .. label .. '" is an empty version: write one, or remove it') end
  local allowed = {}
  for _, member in ipairs(RICH_MEMBERS) do allowed[member] = true end
  refuse_unknown_members(value, label, allowed, "a version")
  for _, member in ipairs({ "require", "strictly", "prefer" }) do
    if value[member] ~= nil and type(value[member]) ~= "string" then
      refuse('"' .. label .. "." .. member .. '" must be a string, not a ' .. type(value[member]))
    end
  end
  if value.reject ~= nil and not is_string_list(value.reject) then
    refuse('"' .. label .. '.reject" must be a list of versions')
  end
  if value.rejectAll ~= nil and type(value.rejectAll) ~= "boolean" then
    refuse('"' .. label .. '.rejectAll" must be true or false')
  end
end

--- @param versions the catalog's `versions`, which a `{ ref }` must name, nil where no ref is taken
local function checked_version(value, label, versions)
  if type(value) == "string" then return end
  if type(value) ~= "table" then
    refuse('"' .. label .. '" must be a version string or a table of require, strictly, prefer, reject'
           .. " and rejectAll, not a " .. type(value))
  end
  if versions ~= nil and value.ref ~= nil then
    if next(value, next(value)) ~= nil or type(value.ref) ~= "string" or versions[value.ref] == nil then
      refuse('"' .. label .. '.ref" must name an alias of this catalog\'s versions, and stand alone')
    end
    return
  end
  checked_rich_version(value, label)
end

local function checked_library(value, label, versions)
  if type(value) ~= "table" then refuse('"' .. label .. '" must be a table, not a ' .. type(value)) end
  refuse_unknown_members(value, label, LIBRARY_MEMBERS, "a library")
  local by_module = value.module ~= nil
  local by_name = value.group ~= nil or value.name ~= nil
  if by_module == by_name or (by_module and type(value.module) ~= "string")
     or (by_name and (type(value.group) ~= "string" or type(value.name) ~= "string")) then
    refuse('"' .. label .. '" must name its module as module = "group:name", or as group and name,'
           .. " not both")
  end
  if value.version ~= nil then checked_version(value.version, label .. ".version", versions) end
end

local function checked_plugin(value, label, versions)
  if type(value) ~= "table" then refuse('"' .. label .. '" must be a table, not a ' .. type(value)) end
  refuse_unknown_members(value, label, PLUGIN_MEMBERS, "a plugin")
  if type(value.id) ~= "string" then refuse('"' .. label .. '" must name its plugin by id') end
  if value.version ~= nil then checked_version(value.version, label .. ".version", versions) end
end

local function checked_bundle(value, label, libraries)
  if not is_string_list(value) then refuse('"' .. label .. '" must be a list of library aliases') end
  for _, alias in ipairs(value) do
    if libraries[alias] == nil then
      refuse('"' .. label .. '" names "' .. alias .. '", which is not a library of this catalog')
    end
  end
end

local function checked_section(catalog, label, section)
  local value = catalog[section]
  if value == nil then return {} end
  if type(value) ~= "table" then
    refuse('"' .. label .. "." .. section .. '" must be a table of alias to entry, not a ' .. type(value))
  end
  for _, alias in ipairs(sorted_keys(value)) do
    if type(alias) ~= "string" or string.find(alias, ".", 1, true) ~= nil then
      refuse('"' .. label .. "." .. section .. '" holds the alias "' .. tostring(alias) .. '": write "-"'
             .. " for each \".\", which gives the same accessor")
    end
  end
  return value
end

local function checked_catalog(catalog, label)
  if type(catalog) ~= "table" then
    refuse('"' .. label .. '" must be a table of versions, libraries, bundles and plugins, not a '
           .. type(catalog))
  end
  local allowed = {}
  for _, section in ipairs(SECTIONS) do allowed[section] = true end
  refuse_unknown_members(catalog, label, allowed, "a catalog")
  local versions = checked_section(catalog, label, "versions")
  local libraries = checked_section(catalog, label, "libraries")
  for _, alias in ipairs(sorted_keys(versions)) do
    checked_version(versions[alias], label .. ".versions." .. alias, nil)
  end
  for _, alias in ipairs(sorted_keys(libraries)) do
    checked_library(libraries[alias], label .. ".libraries." .. alias, versions)
  end
  local bundles = checked_section(catalog, label, "bundles")
  for _, alias in ipairs(sorted_keys(bundles)) do
    checked_bundle(bundles[alias], label .. ".bundles." .. alias, libraries)
  end
  local plugins = checked_section(catalog, label, "plugins")
  for _, alias in ipairs(sorted_keys(plugins)) do
    checked_plugin(plugins[alias], label .. ".plugins." .. alias, versions)
  end
end

--- @param carries_verbatim whether the build the key sits in sets `verbatim`
--- @return a list of { name, catalog } in name order, empty when `value` is nil
function catalogs.checked(value, label, carries_verbatim)
  if value == nil then return {} end
  if type(value) ~= "table" then
    refuse('"' .. label .. '" must be a table of catalog name to catalog, not a ' .. type(value))
  end
  if not carries_verbatim then
    refuse('"' .. label .. '" serves carried code and nothing else: set "verbatim" beside it, or remove it')
  end
  local entries = {}
  for _, name in ipairs(sorted_keys(value)) do
    if not is_identifier(name) then
      refuse('"' .. label .. '" names the catalog "' .. tostring(name) .. '", which is not an identifier'
             .. " settings.gradle can name: not a Groovy keyword, and not " .. CONVENTION_CATALOG_NAME)
    end
    checked_catalog(value[name], label .. "." .. name)
    entries[#entries + 1] = { name = name, catalog = value[name] }
  end
  return entries
end

--- Where a catalog is generated, below the derived root its settings read it
--- from.
---
--- @implNote under the derived root's `build/`, which no root link takes, so
--- the write never reaches the user's own files.
function catalogs.file_of(name)
  return DIRECTORY .. name .. ".versions.toml"
end

local function escaped_byte(character)
  return string.format("\\u%04X", string.byte(character))
end

local function toml_string(text)
  local escaped = string.gsub(string.gsub(tostring(text), "\\", "\\\\"), '"', '\\"')
  escaped = string.gsub(escaped, "[%c]", escaped_byte)
  return '"' .. escaped .. '"'
end

local function toml_key(key)
  if string.match(key, "^[%w_-]+$") ~= nil then return key end
  return toml_string(key)
end

local function string_list(items)
  local quoted = {}
  for index, item in ipairs(items) do quoted[index] = toml_string(item) end
  return "[" .. table.concat(quoted, ", ") .. "]"
end

local function rich_version(value)
  local fields = {}
  for _, member in ipairs(RICH_MEMBERS) do
    local field = value[member]
    if type(field) == "string" then
      fields[#fields + 1] = member .. " = " .. toml_string(field)
    elseif type(field) == "boolean" then
      fields[#fields + 1] = member .. " = " .. tostring(field)
    elseif field ~= nil then
      fields[#fields + 1] = member .. " = " .. string_list(field)
    end
  end
  return "{ " .. table.concat(fields, ", ") .. " }"
end

local function version_field(version)
  if version == nil then return "" end
  if type(version) == "string" then return ", version = " .. toml_string(version) end
  if version.ref ~= nil then return ", version.ref = " .. toml_string(version.ref) end
  return ", version = " .. rich_version(version)
end

local function version_lines(versions)
  local lines = {}
  for _, alias in ipairs(sorted_keys(versions)) do
    local version = versions[alias]
    local value = type(version) == "string" and toml_string(version) or rich_version(version)
    lines[#lines + 1] = toml_key(alias) .. " = " .. value
  end
  return lines
end

local function library_lines(libraries)
  local lines = {}
  for _, alias in ipairs(sorted_keys(libraries)) do
    local library = libraries[alias]
    local coordinates = library.module ~= nil and "module = " .. toml_string(library.module)
                        or "group = " .. toml_string(library.group) .. ", name = " .. toml_string(library.name)
    lines[#lines + 1] = toml_key(alias) .. " = { " .. coordinates .. version_field(library.version) .. " }"
  end
  return lines
end

local function bundle_lines(bundles)
  local lines = {}
  for _, alias in ipairs(sorted_keys(bundles)) do
    lines[#lines + 1] = toml_key(alias) .. " = " .. string_list(bundles[alias])
  end
  return lines
end

local function plugin_lines(plugins)
  local lines = {}
  for _, alias in ipairs(sorted_keys(plugins)) do
    local plugin = plugins[alias]
    lines[#lines + 1] = toml_key(alias) .. " = { id = " .. toml_string(plugin.id)
                        .. version_field(plugin.version) .. " }"
  end
  return lines
end

local function append_section(sections, header, lines)
  if #lines == 0 then return end
  sections[#sections + 1] = header .. "\n" .. table.concat(lines, "\n") .. "\n"
end

--- A checked catalog as Gradle's `.versions.toml`.
---
--- @implNote every table is written sorted: core hands a plugin its tables in
--- an order that changes from run to run, and the file is generated on every one.
function catalogs.versions_toml(catalog)
  local sections = {}
  append_section(sections, "[versions]", version_lines(catalog.versions or {}))
  append_section(sections, "[libraries]", library_lines(catalog.libraries or {}))
  append_section(sections, "[bundles]", bundle_lines(catalog.bundles or {}))
  append_section(sections, "[plugins]", plugin_lines(catalog.plugins or {}))
  return table.concat(sections, "\n")
end

--- Each generated catalog of a build, as { path below its derived root, text }.
function catalogs.files_of(entries)
  local files = {}
  for _, entry in ipairs(entries) do
    files[#files + 1] = { path = catalogs.file_of(entry.name), text = catalogs.versions_toml(entry.catalog) }
  end
  return files
end

--- @implNote `defaultLibrariesExtensionName` keeps Gradle from registering the
--- conventional `gradle/libs.versions.toml` as `libs` a second time while the
--- real file is still linked into the derived root, which fails on both majors
--- with "you can only call the 'from' method a single time" (measured on 7.6.4
--- and 9.6.0, D-190). The file then reads as a catalog of this reserved name.
--- @param entries the list `checked` returns
function catalogs.settings_lines(entries)
  if #entries == 0 then return {} end
  local lines = {
    "dependencyResolutionManagement {",
    "  defaultLibrariesExtensionName = " .. groovy.quoted(CONVENTION_CATALOG_NAME),
    "  versionCatalogs {",
  }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = "    " .. entry.name .. " { from(files(" .. groovy.quoted(catalogs.file_of(entry.name)) .. ")) }"
  end
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return lines
end

return catalogs
