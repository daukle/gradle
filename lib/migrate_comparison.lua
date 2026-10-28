--- The checks that need the generated build's model: for every old project
--- and included build, what the generated counterpart of the same path does
--- not apply, register, configure or resolve.
local migrate_comparison = {}

local migrate_blockers = daukle.require("lib/migrate_blockers")
local migrate_classpaths = daukle.require("lib/migrate_classpaths")
local migrate_task_values = daukle.require("lib/migrate_task_values")
local migrate_paths = daukle.require("lib/migrate_paths")
local migrate_surface = daukle.require("lib/migrate_surface")
local migrate_real_tree = daukle.require("lib/migrate_real_tree")
local carried = daukle.require("lib/carried")
local tables = daukle.require("lib/tables")

local append = tables.append
local CURRENT_BUILD = ":"

local function project_blockers(old, generated, where, comparison)
  local blockers = {}
  append(blockers, migrate_blockers.core_plugins(old, generated, where))
  append(blockers, migrate_blockers.third_party_plugins(old.plugins, generated.plugins, where, ""))
  append(blockers, migrate_blockers.extension_differences(old.extensions, generated.extensions, where, "configure"))
  append(blockers, migrate_blockers.task_difference(old, generated, where))
  append(blockers, migrate_task_values.differences(old, generated, { where = where, root = comparison.root }))
  append(blockers, migrate_task_values.application(old, generated, where))
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
  return migrate_surface.blocker(construct, where, "has no counterpart in the build daukle/gradle generates"
                                 .. " from the translated keys, so nothing it holds could be compared",
                                 migrate_surface.UNCOVERED_ROW)
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

local function module_names(built)
  local names = {}
  for _, module in ipairs(built.declared or {}) do names[#names + 1] = module.name end
  return names
end

--- The main build's models as the comparison reads them: as they are, or
--- for a carrying build relative to the real root (lib/migrate_real_tree).
local function compared_models(model, built, generated)
  if not carried.build_carries(built.config) then return model, generated end
  return migrate_real_tree.old(model, model.rootDir),
         migrate_real_tree.generated(generated, generated.rootDir, model.rootDir, module_names(built))
end

--- An included build's old and generated root project, mapped like the main
--- build's when that included build carries.
local function compared_included(built, record, old_root, counterpart)
  local generated = counterpart.model.projects[1]
  local block = (built.config.builds or {})[record.dir] or {}
  if block.logic == nil then return record.project, generated end
  local real_root = old_root .. "/" .. record.dir
  return migrate_real_tree.old(record.project, real_root),
         migrate_real_tree.generated(generated, counterpart.model.rootDir, real_root, {})
end

--- @param model            the old root build's model
--- @param built            what `translate_build.build` returned
--- @param generated        the generated root build's model
--- @param generated_builds the generated included builds' models, by directory, each { identity, model }
--- @param settings         the path blockers about the settings name
--- @param dir              the directory of the build, relative to the one migrate runs in
--- @param withheld         the projects whose code was withheld, which are not compared: their
---                         catalog blocker already stops the migration, and every task that code
---                         registers would be reported again as missing
function migrate_comparison.blockers(model, built, generated, generated_builds, settings, dir, withheld)
  withheld = withheld or {}
  local comparison = { identities = identities_of(built, generated_builds), unpinned = union_unpinned(built.projects),
                       root = dir or "." }
  local old_root = model.rootDir
  local old_model, generated_model = compared_models(model, built, generated)
  local blockers = settings_blockers(old_model, generated_model, settings)
  local old_projects, generated_projects = by_path(old_model), by_path(generated_model)
  for _, entry in ipairs(built.projects) do
    local counterpart = generated_projects[entry.project.path]
    if withheld[entry.project] == nil then
      if counterpart == nil then
        blockers[#blockers + 1] = missing(entry.project.path, entry.where)
      else
        append(blockers, project_blockers(old_projects[entry.project.path], counterpart, entry.where, comparison))
      end
    end
  end
  for _, record in ipairs(built.builds) do
    local counterpart = generated_builds[record.dir]
    if withheld[record.project] == nil then
      if counterpart == nil then
        blockers[#blockers + 1] = missing(record.dir, record.where)
      else
        local build_comparison = { identities = comparison.identities, unpinned = record.unpinned,
                                   root = migrate_paths.within(dir, record.dir) }
        local old, new = compared_included(built, record, old_root, counterpart)
        append(blockers, project_blockers(old, new, record.where, build_comparison))
      end
    end
  end
  return blockers
end

return migrate_comparison
