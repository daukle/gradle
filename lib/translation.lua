--- The state one translation of a dumped model carries: its blockers, the
--- environment gate every written value passes, and the pin a resolved row
--- becomes.
local translation = {}

local migrate_surface = daukle.require("lib/migrate_surface")
local model_dump = daukle.require("lib/model_dump")
local tables = daukle.require("lib/tables")

local CONFIGURATIONS_ROW = migrate_surface.CONFIGURATIONS_ROW
local PLUGIN_REPOSITORY_PREFIX = "__plugin_repository__"
local SNAPSHOT_SUFFIX = "-SNAPSHOT"

local function environment_index(model)
  local index = {}
  for _, match in ipairs(model.environmentMatches or {}) do index[match.value] = match.names end
  return index
end

--- @param build { model = <the whole model>, dir = <context.dir>, where = <the path blockers name>,
---                prefix? = <the model's root as seen from context.dir, "" or ending in "/">,
---                name? = <the module or included build the project becomes>,
---                includedPluginIds? = <set of the plugin ids included builds declare>,
---                includedPluginBuilds? = <set of the identity paths of the builds declaring them>,
---                inheritedBuildscript? = <the resolved buildscript rows of the project's ancestors> }
function translation.new(build)
  return { model = build.model, dir = build.dir, where = build.where, blockers = {}, blocked = {},
           environment = environment_index(build.model), prefix = build.prefix or "", name = build.name,
           included_plugin_ids = build.includedPluginIds or {},
           included_plugin_builds = build.includedPluginBuilds or {},
           inherited_buildscript = build.inheritedBuildscript or {},
           requires = {}, required_builds = {}, unpinned = {} }
end

function translation.block(state, construct, why, surface)
  local key = construct .. "\0" .. why
  if state.blocked[key] then return end
  state.blocked[key] = true
  state.blockers[#state.blockers + 1] = migrate_surface.blocker(construct, state.where, why, surface)
end

--- The model value, or nil with a blocker when it holds an environment
--- variable's value at dump time, whole or inside it.
---
--- @implNote a build that reads a secret at configuration time evaluates it to
--- a plain string, so the value itself is the only signal the model has, and a
--- value that passes this gate is written into a committed daukle.toml. A
--- string built from a model string, such as an included build's source root
--- under its directory, is not in the model's matches, so its marker decides.
function translation.carried(state, value, construct)
  if type(value) ~= "string" then return value end
  local names = state.environment[value] or model_dump.environment_names(value)
  if names == nil then return value end
  translation.block(state, construct, "holds the value of the environment variable "
                    .. table.concat(names, ", ") .. ", and writing it would commit what may be a"
                    .. " secret into daukle.toml", migrate_surface.UNCOVERED_ROW)
  return nil
end

function translation.is_unrendered(value)
  return type(value) == "table" and value["$unrendered"] ~= nil
end

local function plugin_management_repository(state, name)
  for _, repository in ipairs(state.model.pluginManagementRepositories or {}) do
    if repository.name == name then return repository end
  end
  return nil
end

--- The repository a resolved row names, looked up in `repositories`.
---
--- @implNote under `pluginManagement { repositories }` a buildscript lists
--- `__plugin_repository__<name>` with no url while its rows name plain
--- `<name>`, so the url comes from the settings' repository of that name.
local function repository_named(state, repositories, name)
  if name == nil then return nil end
  if string.sub(name, 1, #PLUGIN_REPOSITORY_PREFIX) == PLUGIN_REPOSITORY_PREFIX then
    return plugin_management_repository(state, string.sub(name, #PLUGIN_REPOSITORY_PREFIX + 1))
  end
  for _, repository in ipairs(repositories or {}) do
    if repository.name == name then return repository end
    if repository.name == PLUGIN_REPOSITORY_PREFIX .. name then
      return plugin_management_repository(state, name)
    end
  end
  return nil
end

local function with_trailing_slash(url)
  if string.sub(url, -1) == "/" then return url end
  return url .. "/"
end

local function maven_path(row)
  return (string.gsub(row.group, "%.", "/")) .. "/" .. row.module .. "/" .. row.version .. "/" .. row.fileName
end

--- @implNote an artifact transform hands the classpath a file it made, still
--- under the component's identifier: the IntelliJ Platform plugin unpacks a
--- Marketplace plugin's zip into its inner jars. Pinned at the component's
--- Maven path, such a file is a 404 that raises inside the render and loses
--- every blocker the migration found.
local function is_in_maven_layout(row)
  local prefix = row.module .. "-" .. row.version
  return string.sub(row.fileName, 1, #prefix) == prefix
end

--- Why a resolved row cannot be pinned, or nil when it can.
local function unpinnable(row, repository)
  if row.kind == "project" then
    return "is a project of this build or of an included one, which no pinned entry can name"
  end
  if row.kind ~= "module" then
    return "has no repository: a files(), flatDir or gradleApi() dependency, which no pinned entry can name"
  end
  if row.sha256 == nil then return "resolved to no file, so there is nothing to pin" end
  if string.sub(row.version, -#SNAPSHOT_SUFFIX) == SNAPSHOT_SUFFIX then
    return "is a snapshot, which a pinned url and digest cannot follow"
  end
  if repository == nil or repository.url == nil then
    return "resolved from a repository the model names no url for"
  end
  if repository.kind ~= "maven" then
    return "resolved from " .. repository.name .. ", which is not a Maven layout"
  end
  if string.sub(repository.url, 1, 5) == "file:" then
    return "resolved from " .. repository.name .. ", a file: repository that exists on this machine only"
  end
  if not is_in_maven_layout(row) then
    return "resolved to files its Maven layout does not hold, made by an artifact transform, so no pinned url"
           .. " can name them"
  end
  return nil
end

local function settings_repositories(state)
  local management = ((state.model.settingsCore or {}).dependencyResolutionManagement or {})
  if type(management) ~= "table" or translation.is_unrendered(management) then return {}, nil end
  local repositories = {}
  local by_name = type(management.repositories) == "table" and management.repositories or {}
  for _, name in ipairs(tables.sorted_keys(by_name)) do
    local repository = by_name[name]
    repositories[#repositories + 1] = { name = name, kind = repository.kind, type = repository.type,
                                        url = repository.url }
  end
  return repositories, management.repositoriesMode
end

--- The repositories a project's own rows resolved from: its own, unless
--- the settings' `dependencyResolutionManagement` decides.
---
--- @implNote `PREFER_PROJECT`, Gradle's default, takes the settings'
--- repositories only when the project declares none; `PREFER_SETTINGS` and
--- `FAIL_ON_PROJECT_REPOS` always take them.
function translation.project_repositories(state, project)
  local own = project.repositories or {}
  local settings, mode = settings_repositories(state)
  if mode == "PREFER_SETTINGS" or mode == "FAIL_ON_PROJECT_REPOS" or #own == 0 then return settings end
  return own
end

--- The pinned entry for a resolved artifact, in the form `maven:resolve` writes
--- and `daukle/gradle` reads: the repository url plus the Maven layout path,
--- the sha256 of Gradle's cached file, and `as = "<artifact> <version>"`.
--- @param repositories the repositories of the scope that resolved the row
function translation.pin_of(state, repositories, row)
  local repository = repository_named(state, repositories, row.repository)
  local why = unpinnable(row, repository)
  if why ~= nil then
    state.unpinned[row.component] = true
    translation.block(state, row.component, why, CONFIGURATIONS_ROW)
    return nil
  end
  local parts = { repository.url, row.group, row.module, row.version, row.fileName }
  for _, part in ipairs(parts) do
    if translation.carried(state, part, row.component) == nil then return nil end
  end
  return { url = with_trailing_slash(repository.url) .. maven_path(row), sha256 = row.sha256,
           as = row.module .. " " .. row.version }
end

return translation
