--- Each resolved classpath of an old project compared with the same
--- configuration of its project in the build `daukle/gradle` generates, so a
--- translation that moved, dropped or added an entry blocks rather than
--- builds differently.
---
--- @implNote an entry is compared by its file's sha256, because the generated
--- build holds the same bytes as a file from daukle's cache rather than as a
--- module, and a project by its build and path. Order is not compared: the
--- writer renders configurations in its own fixed order.
local migrate_classpaths = {}

local model_dump = daukle.require("lib/model_dump")

local CONFIGURATIONS_ROW = "GRADLE-SURFACE.md: 2. Dependency configurations"
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

local function signatures(rows, identity_of, skipped)
  local out = {}
  for _, row in ipairs(rows or {}) do
    if not skipped[row.component] then out[signature(row, identity_of)] = display(row) end
  end
  return out
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
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
  return { construct = construct, where = where, why = why, surface = CONFIGURATIONS_ROW }
end

local function compare_one(configuration, old, new, where, blockers)
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

--- @param options { where, unpinned = <set of components already blocked>,
---                  identities = <old build identity path -> generated identity path> }
function migrate_classpaths.differences(old_project, generated_project, options)
  local blockers = {}
  local old = old_groups(old_project)
  local new = grouped(generated_project)
  local same = {}
  for _, identity in pairs(options.identities) do same[identity] = identity end
  for _, configuration in ipairs(sorted_keys(old)) do
    compare_one(configuration, signatures(old[configuration], options.identities, options.unpinned or {}),
                signatures(new[configuration], same, {}), options.where, blockers)
  end
  return blockers
end

return migrate_classpaths
