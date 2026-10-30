--- Each resolved classpath of an old project compared with the same
--- configuration of its project in the build `daukle/gradle` generates, so a
--- translation that moved, dropped or added an entry blocks rather than
--- builds differently.
---
--- @implNote an entry is compared by its file's sha256, because the generated
--- build holds the same bytes as a file from daukle's cache rather than as a
--- module, and a project by its build and path. Order is compared only between
--- two entries holding a class of the same name, which the dump marks, because
--- there the earlier entry wins; elsewhere the writer's grouping by key
--- reorders entries with no effect.
local migrate_classpaths = {}

local model_dump = daukle.require("lib/model_dump")
local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")

local sorted_keys = tables.sorted_keys
local CURRENT_BUILD = ":"

local function grouped(project)
  local groups = {}
  for _, row in ipairs((project.dependencies or {}).resolved or {}) do
    groups[row.configuration] = groups[row.configuration] or {}
    table.insert(groups[row.configuration], row)
  end
  return groups
end

local function signature(row, identity_of)
  if row.kind == "project" then
    return "project " .. (identity_of[row.build] or row.build) .. " " .. row.project
  end
  if row.sha256 ~= nil then return "file " .. row.sha256 end
  return "unresolved " .. row.component .. " " .. (row.fileName or "")
end

local function display(row)
  if row.kind == "project" then
    if row.build == CURRENT_BUILD then return row.project end
    return "build " .. row.build
  end
  if row.kind == "module" then return row.component end
  return row.fileName or row.component
end

--- The `via` edges of the skipped project rows, in the dump's `project <build> <path>` form.
local function skipped_edges(rows, skipped)
  local edges = {}
  for _, row in ipairs(rows or {}) do
    if row.kind == "project" and skipped[row.component] then
      edges["project " .. row.build .. " " .. row.project] = true
    end
  end
  return edges
end

--- Whether a row is skipped, or reached only through skipped project edges,
--- whose blocker already names the cause.
local function is_skipped(row, skipped, edges)
  if skipped[row.component] then return true end
  local via = row.via or {}
  if #via == 0 then return false end
  for _, edge in ipairs(via) do
    if not edges[edge] then return false end
  end
  return true
end

--- A configuration's entries as signatures: `display` maps each to how a
--- blocker names it, `order` lists them by first appearance, `overlaps` to the
--- digests of the earlier entries holding a class of the same name.
local function signatures(rows, identity_of, skipped)
  local out = { display = {}, order = {}, overlaps = {} }
  local edges = skipped_edges(rows, skipped)
  for _, row in ipairs(rows or {}) do
    local key = signature(row, identity_of)
    if not is_skipped(row, skipped, edges) and out.display[key] == nil then
      out.display[key] = display(row)
      out.order[#out.order + 1] = key
      out.overlaps[key] = row.overlaps
    end
  end
  return out
end

local function test_runtime_configuration(project)
  local sets = ((project.extensions or {}).sourceSets or {}).value
  local test = type(sets) == "table" and sets.test or nil
  return type(test) == "table" and test.runtimeClasspath or nil
end

--- The old project's rows by configuration, with the launcher the dump
--- resolved for a JUnit Platform engine on the test runtime classpath, where
--- Gradle 8 put it at test time and the generated build declares it.
local function old_groups(project)
  local groups = grouped(project)
  local launcher = groups[model_dump.IMPLIED_LAUNCHER]
  groups[model_dump.IMPLIED_LAUNCHER] = nil
  local test_runtime = test_runtime_configuration(project)
  if launcher ~= nil and test_runtime ~= nil then
    groups[test_runtime] = groups[test_runtime] or {}
    for _, row in ipairs(launcher) do table.insert(groups[test_runtime], row) end
  end
  return groups
end

local function blocker(construct, where, why)
  return migrate_surface.blocker(construct, where, why, migrate_surface.CONFIGURATIONS_ROW)
end

local function compare_membership(configuration, old, new, where, blockers)
  for _, key in ipairs(sorted_keys(old)) do
    if new[key] == nil then
      blockers[#blockers + 1] = blocker(configuration .. " " .. old[key], where, "is on it in the old build and"
                                        .. " not in the build daukle/gradle generates from the translated keys")
    end
  end
  for _, key in ipairs(sorted_keys(new)) do
    if old[key] == nil then
      blockers[#blockers + 1] = blocker(configuration .. " " .. new[key], where, "is on it only in the build"
                                        .. " daukle/gradle generates from the translated keys")
    end
  end
end

--- Blocks an entry the generated build puts ahead of an earlier entry of
--- the old build that holds a class of the same name.
local function compare_precedence(configuration, old, new, where, blockers)
  local position = {}
  for index, key in ipairs(new.order) do position[key] = index end
  for _, key in ipairs(old.order) do
    for _, digest in ipairs(old.overlaps[key] or {}) do
      local earlier = "file " .. digest
      if position[key] ~= nil and position[earlier] ~= nil and position[key] < position[earlier] then
        blockers[#blockers + 1] = blocker(configuration .. " " .. old.display[key], where, "holds a class of the same"
                                          .. " name as " .. (old.display[earlier] or digest) .. ", which the old build"
                                          .. " loads first and the build daukle/gradle generates from the translated"
                                          .. " keys loads after it")
      end
    end
  end
end

local function configuration_names(old, new)
  local names = {}
  for name in pairs(old) do names[name] = true end
  for name in pairs(new) do names[name] = true end
  return sorted_keys(names)
end

--- @param options { where, unpinned = <set of components already blocked>,
---                  identities = <old build identity path -> generated identity path> }
function migrate_classpaths.differences(old_project, generated_project, options)
  local blockers = {}
  local old = old_groups(old_project)
  local new = grouped(generated_project)
  local same = {}
  for _, identity in pairs(options.identities) do same[identity] = identity end
  for _, configuration in ipairs(configuration_names(old, new)) do
    local old_entries = signatures(old[configuration], options.identities, options.unpinned or {})
    local new_entries = signatures(new[configuration], same, {})
    compare_membership(configuration, old_entries.display, new_entries.display, options.where, blockers)
    compare_precedence(configuration, old_entries, new_entries, options.where, blockers)
  end
  return blockers
end

return migrate_classpaths
