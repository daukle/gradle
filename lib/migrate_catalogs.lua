--- The version catalogs a migration writes for carried code to read: each one
--- rendered as TOML from what the dump read back out of Gradle (spec D-190,
--- sections 3.2 and 3.5).
local migrate_catalogs = {}

local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")

local sorted_keys = tables.sorted_keys

--- @param build "root" or the included build's directory
function migrate_catalogs.file_path(build, name, instance)
  return "daukle/" .. instance .. "/catalogs/" .. build .. "/" .. name .. ".versions.toml"
end

local function boundary_blocker(construct, where, why)
  return migrate_surface.blocker(construct, where, why, migrate_surface.BOUNDARY_ROW)
end

local function toml_string(text)
  local escaped = string.gsub(string.gsub(tostring(text), "\\", "\\\\"), '"', '\\"')
  return '"' .. escaped .. '"'
end

--- @implNote Gradle lists `my-lib` and `other_lib` as `my.lib` and
--- `other.lib`, and a dotted TOML key is a nested table, so each `.` is
--- written as `-`, which yields the same accessor.
local function key_of(alias)
  return (string.gsub(alias, "%.", "-"))
end

local function text_or_empty(value)
  if value == nil then return "" end
  return value
end

local function normalized(constraint)
  constraint = constraint or {}
  return { required = text_or_empty(constraint.required), strictly = text_or_empty(constraint.strictly),
           prefer = text_or_empty(constraint.prefer), rejected = constraint.rejected or {} }
end

local function is_empty(constraint)
  return constraint.required == "" and constraint.strictly == "" and constraint.prefer == ""
end

--- @implNote `strictly` sets the required version as well, so `require` is
--- written only where it says something `strictly` does not.
local function constraint_value(constraint)
  if constraint.strictly == "" and constraint.prefer == "" then return toml_string(constraint.required) end
  local fields = {}
  if constraint.required ~= "" and constraint.required ~= constraint.strictly then
    fields[#fields + 1] = "require = " .. toml_string(constraint.required)
  end
  if constraint.strictly ~= "" then fields[#fields + 1] = "strictly = " .. toml_string(constraint.strictly) end
  if constraint.prefer ~= "" then fields[#fields + 1] = "prefer = " .. toml_string(constraint.prefer) end
  return "{ " .. table.concat(fields, ", ") .. " }"
end

local function same_constraint(left, right)
  return left.required == right.required and left.strictly == right.strictly and left.prefer == right.prefer
         and tables.deep_equal(left.rejected, right.rejected)
end

--- The one version alias whose constraint is exactly this one, or nil.
local function version_reference(constraint, versions)
  local found = nil
  for _, alias in ipairs(sorted_keys(versions)) do
    if same_constraint(constraint, normalized(versions[alias])) then
      if found ~= nil then return nil end
      found = alias
    end
  end
  return found
end

local function rejection_blockers(catalog_name, section, entries, constraint_of, where)
  local blockers = {}
  for _, alias in ipairs(sorted_keys(entries)) do
    local rejected = normalized(constraint_of(entries[alias])).rejected
    if #rejected > 0 then
      blockers[#blockers + 1] = boundary_blocker(catalog_name .. "." .. section .. "." .. alias, where,
        "rejects " .. table.concat(rejected, ", ") .. ", and a version catalog the migration writes"
        .. " carries no rejected version, so it would accept one the old build refused")
    end
  end
  return blockers
end

local function itself(constraint) return constraint end
local function version_of(entry) return (entry or {}).version end

local function version_lines(versions)
  local lines = {}
  for _, alias in ipairs(sorted_keys(versions)) do
    lines[#lines + 1] = key_of(alias) .. " = " .. constraint_value(normalized(versions[alias]))
  end
  return lines
end

local function library_version_field(constraint, versions)
  if is_empty(constraint) then return "" end
  local reference = version_reference(constraint, versions)
  if reference ~= nil then return ", version.ref = " .. toml_string(key_of(reference)) end
  return ", version = " .. constraint_value(constraint)
end

local function library_lines(libraries, versions)
  local lines = {}
  for _, alias in ipairs(sorted_keys(libraries)) do
    local library = libraries[alias]
    lines[#lines + 1] = key_of(alias) .. " = { module = " .. toml_string(library.module)
                        .. library_version_field(normalized(library.version), versions) .. " }"
  end
  return lines
end

local function plugin_lines(plugins)
  local lines = {}
  for _, alias in ipairs(sorted_keys(plugins)) do
    local plugin = plugins[alias]
    local constraint = normalized(plugin.version)
    local version = is_empty(constraint) and "" or ", version = " .. constraint_value(constraint)
    lines[#lines + 1] = key_of(alias) .. " = { id = " .. toml_string(plugin.id) .. version .. " }"
  end
  return lines
end

local function aliases_by_module(libraries)
  local aliases = {}
  for _, alias in ipairs(sorted_keys(libraries)) do
    local module = libraries[alias].module
    aliases[module] = aliases[module] or {}
    aliases[module][#aliases[module] + 1] = alias
  end
  return aliases
end

--- @implNote the dump reads a bundle back as its member modules, not their
--- aliases, so a module that no library or several libraries name cannot be
--- mapped back and blocks by name.
local function bundle_lines(catalog_name, bundles, libraries, where, blockers)
  local lines, aliases = {}, aliases_by_module(libraries)
  for _, bundle in ipairs(sorted_keys(bundles)) do
    local members = {}
    for _, module in ipairs(bundles[bundle]) do
      local candidates = aliases[module] or {}
      if #candidates ~= 1 then
        blockers[#blockers + 1] = boundary_blocker(catalog_name .. ".bundles." .. bundle, where, "holds "
          .. module .. ", which " .. (#candidates == 0 and "no library" or "more than one library")
          .. " of the catalog names, so the bundle cannot be written back as library aliases")
      else
        members[#members + 1] = toml_string(key_of(candidates[1]))
      end
    end
    lines[#lines + 1] = key_of(bundle) .. " = [" .. table.concat(members, ", ") .. "]"
  end
  return lines
end

local function append_section(sections, header, lines)
  if #lines == 0 then return end
  sections[#sections + 1] = header .. "\n" .. table.concat(lines, "\n") .. "\n"
end

--- A dumped catalog as the TOML file that declares it, and the blockers for
--- what that file cannot say.
---
--- @param catalog the dump's { versions, libraries, bundles, plugins } of one catalog
--- @param where   what a blocker names as the place it was found
--- @return { text, blockers }
function migrate_catalogs.rendered(catalog_name, catalog, where)
  local versions, libraries = catalog.versions or {}, catalog.libraries or {}
  local plugins, bundles = catalog.plugins or {}, catalog.bundles or {}
  local blockers = rejection_blockers(catalog_name, "versions", versions, itself, where)
  tables.append(blockers, rejection_blockers(catalog_name, "libraries", libraries, version_of, where))
  tables.append(blockers, rejection_blockers(catalog_name, "plugins", plugins, version_of, where))
  local sections = {}
  append_section(sections, "[versions]", version_lines(versions))
  append_section(sections, "[libraries]", library_lines(libraries, versions))
  append_section(sections, "[bundles]", bundle_lines(catalog_name, bundles, libraries, where, blockers))
  append_section(sections, "[plugins]", plugin_lines(plugins))
  return { text = table.concat(sections, "\n"), blockers = blockers }
end

return migrate_catalogs
