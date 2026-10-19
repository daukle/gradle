--- The checks that need the generated build's model: for every old project
--- and included build, what the generated counterpart of the same path does
--- not apply, register, configure or resolve.
local migrate_comparison = {}

local migrate_blockers = daukle.require("lib/migrate_blockers")
local migrate_classpaths = daukle.require("lib/migrate_classpaths")

local SURFACE = "GRADLE-SURFACE.md: "
local UNCOVERED_ROW = SURFACE .. "6. What this file does NOT yet cover, said plainly"
local CURRENT_BUILD = ":"

local function append(target, source)
  for _, item in ipairs(source) do target[#target + 1] = item end
end

local function project_blockers(old, generated, where, comparison)
  local blockers = {}
  append(blockers, migrate_blockers.core_plugins(old, generated, where))
  append(blockers, migrate_blockers.third_party_plugins(old.plugins, generated.plugins, where, ""))
  append(blockers, migrate_blockers.extension_differences(old.extensions, generated.extensions, where, "configure"))
  append(blockers, migrate_blockers.task_difference(old, generated, where))
  append(blockers, migrate_classpaths.differences(old, generated, { where = where, unpinned = comparison.unpinned,
                                                                    identities = comparison.identities }))
  return blockers
end

local function by_path(model)
  local projects = {}
  for _, project in ipairs((model or {}).projects or {}) do projects[project.path] = project end
  return projects
end

local function missing(construct, where)
  return { construct = construct, where = where, why = "has no counterpart in the build daukle/gradle generates"
           .. " from the translated keys, so nothing it holds could be compared", surface = UNCOVERED_ROW }
end

local function settings_blockers(model, generated, settings)
  local blockers = {}
  append(blockers, migrate_blockers.third_party_plugins(model.settingsPlugins, generated.settingsPlugins, settings,
                                                        "settings "))
  append(blockers, migrate_blockers.core_plugins({ plugins = model.settingsPlugins },
                                                 { plugins = generated.settingsPlugins }, settings))
  append(blockers, migrate_blockers.settings_differences(model.settingsCore, generated.settingsCore, settings))
  append(blockers, migrate_blockers.extension_differences(model.settingsExtensions, generated.settingsExtensions,
                                                          settings, "settingsConfigure"))
  return blockers
end

--- Old build identity path -> the generated build's, for comparing project rows.
local function identities_of(built, generated_builds)
  local identities = { [CURRENT_BUILD] = CURRENT_BUILD }
  for _, record in ipairs(built.builds) do
    local generated = generated_builds[record.dir]
    if generated ~= nil then identities[record.identity] = generated.identity end
  end
  return identities
end

local function union_unpinned(entries)
  local unpinned = {}
  for _, entry in ipairs(entries) do
    for component in pairs(entry.unpinned or {}) do unpinned[component] = true end
  end
  return unpinned
end

--- @param model            the old root build's model
--- @param built            what `translate_build.build` returned
--- @param generated        the generated root build's model
--- @param generated_builds the generated included builds' models, by directory, each { identity, model }
--- @param settings         the path blockers about the settings name
function migrate_comparison.blockers(model, built, generated, generated_builds, settings)
  local comparison = { identities = identities_of(built, generated_builds), unpinned = union_unpinned(built.projects) }
  local blockers = settings_blockers(model, generated, settings)
  local generated_projects = by_path(generated)
  for _, entry in ipairs(built.projects) do
    local counterpart = generated_projects[entry.project.path]
    if counterpart == nil then
      blockers[#blockers + 1] = missing(entry.project.path, entry.where)
    else
      append(blockers, project_blockers(entry.project, counterpart, entry.where, comparison))
    end
  end
  for _, record in ipairs(built.builds) do
    local counterpart = generated_builds[record.dir]
    if counterpart == nil then
      blockers[#blockers + 1] = missing(record.dir, record.where)
    else
      local build_comparison = { identities = comparison.identities, unpinned = record.unpinned }
      append(blockers, project_blockers(record.project, counterpart.model.projects[1], record.where, build_comparison))
    end
  end
  return blockers
end

return migrate_comparison
