--- What a version catalog the migration writes holds differently from the
--- old build's, read back out of both builds' dumps: the proof that
--- `migrate_catalogs` wrote every alias carried code may read (spec D-190,
--- section 3.4).
local migrate_catalog_differences = {}

local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")

local sorted_keys = tables.sorted_keys
local SECTIONS = { "versions", "libraries", "bundles", "plugins" }

local function blocker(construct, where, why)
  return migrate_surface.blocker(construct, where, why, migrate_surface.UNCOVERED_ROW)
end

local function text_or_empty(value)
  if value == nil then return "" end
  return tostring(value)
end

--- @implNote `rejected` is left out: `migrate_catalogs` already blocks a
--- constraint holding one by name, and the written file never carries it.
local function constraint_text(constraint)
  constraint = constraint or {}
  return "require '" .. text_or_empty(constraint.required) .. "', strictly '" .. text_or_empty(constraint.strictly)
         .. "', prefer '" .. text_or_empty(constraint.prefer) .. "'"
end

local function members_text(members)
  return "[" .. table.concat(members or {}, ", ") .. "]"
end

--- Each field of one section's entry as text, by the name a blocker gives it.
local FIELDS = {
  versions = function(constraint) return { version = constraint_text(constraint) } end,
  libraries = function(library)
    return { module = text_or_empty(library.module), version = constraint_text(library.version) }
  end,
  bundles = function(members) return { members = members_text(members) } end,
  plugins = function(plugin) return { id = text_or_empty(plugin.id), version = constraint_text(plugin.version) } end,
}

local function entry_blockers(construct, section, old, generated, where)
  local blockers = {}
  local old_fields, generated_fields = FIELDS[section](old), FIELDS[section](generated)
  for _, field in ipairs(sorted_keys(old_fields)) do
    if old_fields[field] ~= generated_fields[field] then
      blockers[#blockers + 1] = blocker(construct, where, "has " .. field .. " " .. old_fields[field]
        .. " in the old build and " .. generated_fields[field] .. " in the catalog the migration writes")
    end
  end
  return blockers
end

local function section_blockers(catalog_name, section, old_entries, generated_entries, where)
  local blockers = {}
  for _, alias in ipairs(sorted_keys(old_entries or {})) do
    local construct = catalog_name .. "." .. section .. "." .. alias
    local generated = (generated_entries or {})[alias]
    if generated == nil then
      blockers[#blockers + 1] = blocker(construct, where, "is in the old build's catalog and not in the one the"
                                        .. " migration writes, so carried code reading it would fail")
    else
      tables.append(blockers, entry_blockers(construct, section, old_entries[alias], generated, where))
    end
  end
  return blockers
end

local function catalog_blockers(catalog_name, old, generated, where)
  local blockers = {}
  for _, section in ipairs(SECTIONS) do
    tables.append(blockers, section_blockers(catalog_name, section, old[section], generated[section], where))
  end
  return blockers
end

--- The blockers for every catalog a build declares by its `catalogs` key.
---
--- @implNote only the declared catalogs are compared: the generated build
--- holds no other, apart from the conventional `gradle/libs.versions.toml`
--- it registers under the reserved name `daukleConventionCatalog`.
---
--- @param declared  the build's `catalogs` key, name -> path, or nil
--- @param old       the old build's dumped catalogs, by name
--- @param generated the generated build's dumped catalogs, by name
--- @param where     what a blocker names as the place it was found
function migrate_catalog_differences.blockers(declared, old, generated, where)
  local blockers = {}
  for _, name in ipairs(sorted_keys(declared or {})) do
    local old_catalog, generated_catalog = (old or {})[name], (generated or {})[name]
    if old_catalog == nil or generated_catalog == nil then
      blockers[#blockers + 1] = blocker(name, where, "is a version catalog the migration declares, and the"
                                        .. " dump of the old or the generated build holds no contents for it,"
                                        .. " so the two could not be compared")
    else
      tables.append(blockers, catalog_blockers(name, old_catalog, generated_catalog, where))
    end
  end
  return blockers
end

return migrate_catalog_differences
