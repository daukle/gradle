--- The version catalogs a migration declares for carried code to read: each
--- one turned from what the dump read back out of Gradle into the
--- `catalogs.<name>` key lib/catalogs renders (spec D-190, 3.5; spec D-198, 4.4).
local migrate_catalogs = {}

local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")

local sorted_keys = tables.sorted_keys

local function boundary_blocker(construct, where, why)
  return migrate_surface.blocker(construct, where, why, migrate_surface.BOUNDARY_ROW)
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
--- kept only where it says something `strictly` does not.
local function constraint_value(constraint)
  if constraint.strictly == "" and constraint.prefer == "" then return constraint.required end
  local value = {}
  if constraint.required ~= "" and constraint.required ~= constraint.strictly then
    value.require = constraint.required
  end
  if constraint.strictly ~= "" then value.strictly = constraint.strictly end
  if constraint.prefer ~= "" then value.prefer = constraint.prefer end
  return value
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

local function versions_table(versions)
  local out = {}
  for _, alias in ipairs(sorted_keys(versions)) do
    out[key_of(alias)] = constraint_value(normalized(versions[alias]))
  end
  return out
end

local function library_version(constraint, versions)
  if is_empty(constraint) then return nil end
  local reference = version_reference(constraint, versions)
  if reference ~= nil then return { ref = key_of(reference) } end
  return constraint_value(constraint)
end

local function libraries_table(libraries, versions)
  local out = {}
  for _, alias in ipairs(sorted_keys(libraries)) do
    local library = libraries[alias]
    out[key_of(alias)] = { module = library.module,
                           version = library_version(normalized(library.version), versions) }
  end
  return out
end

local function plugins_table(plugins)
  local out = {}
  for _, alias in ipairs(sorted_keys(plugins)) do
    local plugin = plugins[alias]
    local constraint = normalized(plugin.version)
    out[key_of(alias)] = { id = plugin.id, version = (not is_empty(constraint)) and constraint_value(constraint) or nil }
  end
  return out
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
local function bundles_table(catalog_name, bundles, libraries, where, blockers)
  local out, aliases = {}, aliases_by_module(libraries)
  for _, bundle in ipairs(sorted_keys(bundles)) do
    local members = {}
    for _, module in ipairs(bundles[bundle]) do
      local candidates = aliases[module] or {}
      if #candidates ~= 1 then
        blockers[#blockers + 1] = boundary_blocker(catalog_name .. ".bundles." .. bundle, where, "holds "
          .. module .. ", which " .. (#candidates == 0 and "no library" or "more than one library")
          .. " of the catalog names, so the bundle cannot be written back as library aliases")
      else
        members[#members + 1] = key_of(candidates[1])
      end
    end
    out[key_of(bundle)] = members
  end
  return out
end

local function non_empty(section)
  if next(section) == nil then return nil end
  return section
end

--- A dumped catalog as the `catalogs.<name>` value that declares it, and the
--- blockers for what that value cannot say.
---
--- @param catalog the dump's { versions, libraries, bundles, plugins } of one catalog
--- @param where   what a blocker names as the place it was found
--- @return { catalog, blockers }
function migrate_catalogs.table_of(catalog_name, catalog, where)
  local versions, libraries = catalog.versions or {}, catalog.libraries or {}
  local plugins, bundles = catalog.plugins or {}, catalog.bundles or {}
  local blockers = rejection_blockers(catalog_name, "versions", versions, itself, where)
  tables.append(blockers, rejection_blockers(catalog_name, "libraries", libraries, version_of, where))
  tables.append(blockers, rejection_blockers(catalog_name, "plugins", plugins, version_of, where))
  local value = {
    versions = non_empty(versions_table(versions)),
    libraries = non_empty(libraries_table(libraries, versions)),
    bundles = non_empty(bundles_table(catalog_name, bundles, libraries, where, blockers)),
    plugins = non_empty(plugins_table(plugins)),
  }
  return { catalog = value, blockers = blockers }
end

return migrate_catalogs
