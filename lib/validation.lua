local distributions = daukle.require("lib/distributions")
local build_file = daukle.require("lib/build_file")
local module_graph = daukle.require("lib/modules")
local configurations = daukle.require("lib/configurations")
local builds = daukle.require("lib/builds")
local jdks = daukle.require("java:lib/jdks")

local DEFAULT_JDK = "17"

--[[ Gated on the manifest being DECLARATIVE: core accepts a project whose only
     manifest is daukle.lua by falling back to the overlay, and daukle.parse
     refuses to run one. There is no pcall in the sandbox, so an unguarded parse
     is fatal on every command rather than only where the document is wanted,
     which is what daukle/cmake@1.4.0 shipped. ]]
local function declarative_manifest()
  if string.match(daukle.manifest, "%.toml$") == nil then return nil end
  return daukle.parse(daukle.read(daukle.manifest), daukle.manifest)
end

local MANIFEST = declarative_manifest()

--- Whether the manifest ITSELF declares modules, which is the one question a
--- core too old to publish its module list cannot be asked.
---
--- @implNote read from the parsed manifest rather than from a context, because
--- the context is exactly what such a core leaves out. A project whose manifest
--- is daukle.lua cannot be read at all, so this is false there and nothing is
--- refused, which is what every overlay project already gets.
local function manifest_declares_modules(document)
  local declared = document ~= nil and document.modules or nil
  return type(declared) == "table" and next(declared) ~= nil
end

local MANIFEST_DECLARES_MODULES = manifest_declares_modules(MANIFEST)

local function config_of(context)
  return context.toolchain ~= nil and context.toolchain.config or context.config
end

local string_key = module_graph.string_key

--- @implNote core keeps a toolchain's `version` in the config a GENERATE callback
--- sees and drops it from a TASK's, exposing it as context.toolchain.version
--- instead. Reading only `config.version` therefore found a version at generate
--- time, refused an unpinned one correctly, and then provisioned the DEFAULT
--- Gradle in every task. `jdk` is unaffected: core reserves `version` and
--- `dependencies` and passes every other key through both callbacks.
local function gradle_version_of(context)
  return (context.toolchain ~= nil and context.toolchain.version)
         or config_of(context).version
end

local function jdk_version_of(config)
  return string_key(config, "jdk", DEFAULT_JDK)
end

local function jdk_for(context, config)
  return jdks.for_host{ os = context.host.os, arch = context.host.arch,
                        version = jdk_version_of(config) }
end

local function layout_of(config)
  return module_graph.layout_of(nil, config)
end

local function checked_classpath(entries, key)
  if entries == nil then return {} end
  if type(entries) ~= "table" then
    error('"' .. key .. '" must be a list of pinned entries, not a ' .. type(entries), 0)
  end
  for index = 1, #entries do
    local entry = entries[index]
    if type(entry) ~= "table" or type(entry.url) ~= "string"
       or type(entry.sha256) ~= "string" then
      error('"' .. key .. '[' .. index .. ']" needs a url and a sha256: every dependency this'
            .. ' toolchain gives Gradle is pinned before Gradle sees it', 0)
    end
  end
  return entries
end

--- Every pinned entry a configuration holds, keyed by its manifest name.
---
--- @implNote read through one list rather than key by key, so a configuration
--- added to lib/configurations reaches the reader, the renderer, the launcher
--- check and the module key set at once.
local function entries_of_configurations(block, scope)
  local entries = {}
  for index = 1, #configurations.all do
    local key = configurations.all[index].key
    entries[key] = checked_classpath(block[key], scope .. key)
  end
  return entries
end

--- Every declared module with its own block read and shape-checked.
---
--- @implNote `validated` runs this and throws the result away, so a module's
--- classpath is refused by `daukle sync` and not only by the task that would
--- have written its file. One function rather than a second loop beside the
--- writer's: two loops over the same blocks would drift.
local function checked_modules(config, declared, read)
  local blocks = module_graph.blocks_of(config, declared)
  local checked = {}
  for index = 1, #declared do
    local name = declared[index].name
    --[[ A module fault labelled "classpath" would name a key the manifest does
         not hold and that this plugin refuses project-wide. ]]
    local scope = "modules." .. name .. "."
    local block = blocks[name] or {}
    checked[index] = {
      name = name,
      requires = declared[index].requires,
      layout = module_graph.layout_of(name, block),
      main = string_key(block, "main", nil, scope .. "main"),
      entries = entries_of_configurations(block, scope),
      required_builds = builds.required(block, scope .. "requiresBuilds", read),
    }
  end
  module_graph.refuse_two_mains(checked)
  return checked
end

local function project_name(context)
  local name = context.project or "project"
  return (name:match("([^/]+)$") or name)
end

local function checked_builds(context, config)
  local declared = module_graph.declared(context)
  local read = builds.read(config, declared, project_name(context), MANIFEST)
  local release = string_key(config, "release", nil)
  local checked = {}
  for index = 1, #read do
    local build = read[index]
    local scope = "builds." .. build.name .. "."
    checked[index] = { name = build.name, gradle_name = build.gradle_name,
      plugin_build = #build.gradle_plugins > 0, gradle_plugins = build.gradle_plugins,
      layout = module_graph.layout_of(build.name, build.block, "builds"),
      release = string_key(build.block, "release", release, scope .. "release"),
      entries = entries_of_configurations(build.block, scope) }
  end
  return checked, read
end

local function checked_plugins(entries, key, owners)
  key = key or "plugins"
  if entries == nil then return {}, {} end
  if type(entries) ~= "table" then
    error('"' .. key .. '" must be a list of entries, not a ' .. type(entries), 0)
  end
  local pinned, included = {}, {}
  for index = 1, #entries do
    local entry = entries[index]
    local named = type(entry) == "table" and type(entry.id) == "string"
    if named and type(entry.version) == "string" then
      pinned[#pinned + 1] = entry
    elseif named and entry.version == nil and owners and owners[entry.id] ~= nil then
      included[#included + 1] = entry.id
    else
      error('"' .. key .. '[' .. index .. ']" needs an "id" and a "version": the id is what Gradle'
            .. " applies and the version is what the pinned jars are checked against, or name a"
            .. ' plugin an included build declares in "gradlePlugins"', 0)
    end
  end
  return pinned, included
end

--[[ The jar a plugin is applied from is pinned somewhere else entirely, by
     daukle/maven, so nothing links the version the project APPLIES to the
     version it ACQUIRED. Bumping one and not the other is silent: Gradle
     applies whatever jar it was handed. The version has to appear in some
     pinned entry, which the Maven layout puts in the url and which a
     hand-written pin can carry in "as". ]]
local function refuse_a_version_no_pin_carries(plugins, pins, plugins_key, classpath_key)
  for index = 1, #plugins do
    local version = plugins[index].version
    local pinned = version == nil
    for pin = 1, pinned and 0 or #pins do
      local entry = pins[pin]
      if entry.url:find("/" .. version .. "/", 1, true) ~= nil
         or (type(entry.as) == "string" and entry.as:find(" " .. version, 1, true) ~= nil) then
        pinned = true
      end
    end
    if not pinned then
      error('"' .. plugins_key .. '[' .. index .. ']" applies ' .. plugins[index].id .. " "
            .. version .. ', and no entry in "' .. classpath_key .. '" names that version.'
            .. ' This check runs on every command, so "maven:resolve" cannot fix it in place:'
            .. ' remove this entry,'
            .. " resolve the marker at that version, then put it back. Or correct the version"
            .. " here", 0)
    end
  end
end

--- One plugin list and the classpath it is applied from, checked together:
--- the project's `plugins` and `pluginClasspath`, or the settings twins.
--- @return the pinned plugin entries, the pinned classpath entries and the included ids
local function checked_plugin_set(config, plugins_key, classpath_key, owners)
  local plugins, included = checked_plugins(config[plugins_key], plugins_key, owners)
  local jars = checked_classpath(config[classpath_key], classpath_key)
  if #plugins > 0 and #jars == 0 then
    error('"' .. plugins_key .. '" names ' .. #plugins .. ' plugin(s) and "' .. classpath_key
          .. '" is empty: a plugin is applied from a jar daukle pinned. This check runs on every'
          .. ' command, so "maven:resolve" cannot fix it in place: resolve the marker with no "'
          .. plugins_key .. '" block in the manifest, then add the block', 0)
  end
  refuse_a_version_no_pin_carries(config[plugins_key] or {}, jars, plugins_key, classpath_key)
  return plugins, jars, included
end

local function composite_of(context, config)
  local checked, read = checked_builds(context, config)
  local owners = builds.owners(read)
  local plugin_builds, library_builds = {}, {}
  for index = 1, #checked do
    local list = checked[index].plugin_build and plugin_builds or library_builds
    list[#list + 1] = checked[index].name
  end
  local _, _, settings_ids = checked_plugin_set(config, "settingsPlugins",
                                                "settingsPluginClasspath", owners)
  local _, _, project_ids = checked_plugin_set(config, "plugins", "pluginClasspath", owners)
  return { builds = checked, read = read, owners = owners, plugin_builds = plugin_builds,
           library_builds = library_builds, settings_ids = settings_ids,
           project_ids = project_ids, required = builds.required(config, "requiresBuilds", read) }
end

--- @implNote core publishes `context.modules` as a table, empty when the
--- project declares none, so an ABSENT one is a core too old to publish the
--- list at all rather than a project without modules. Refused because nothing
--- downstream can tell the difference: the single-project file would be
--- rendered against source roots a module-shaped repository does not have, and
--- Gradle would report BUILD SUCCESSFUL having compiled nothing.
local function refuse_a_core_that_publishes_no_modules(context)
  if MANIFEST_DECLARES_MODULES and context.modules == nil then
    error('this project declares modules and the daukle running it is too old to publish the'
          .. ' module list, so every module in "[modules]" would be silently ignored: upgrade'
          .. ' daukle, or take the modules back out of the manifest', 0)
  end
end

--- Everything `generate` can check without starting a process or fetching.
---
--- @implNote the module checks live here rather than beside the writer so that
--- `daukle sync` refuses a bad graph. A project that declares modules reaches
--- generate and no task, so a check only the writer ran would be one a user
--- never meets until the first build.
local function validated(context, config)
  refuse_a_core_that_publishes_no_modules(context)
  distributions.for_version(gradle_version_of(context))
  jdk_for(context, config)
  layout_of(config)
  local declared = module_graph.declared(context)
  module_graph.refuse_a_module_key_project_wide(config, declared)
  local record = composite_of(context, config)
  checked_modules(config, declared, record.read)
  entries_of_configurations(config, "")
  string_key(config, "release", nil)
  string_key(config, "main", nil)
  checked_plugin_set(config, "plugins", "pluginClasspath", record.owners)
  checked_plugin_set(config, "settingsPlugins", "settingsPluginClasspath", record.owners)
  --[[ Rendered and thrown away, so a tree this refuses is refused by `daukle
       check` rather than by the task that would have written it. Running the
       real renderer is what stops the refusal drifting from the writer. ]]
  build_file.configuration(config.configure)
  build_file.configuration(config.settingsConfigure, nil, "settingsConfigure")
end

--- The settings plugins and settings configure blocks the manifest declares,
--- or nil when it declares neither, which is also what decides whether
--- settings.gradle applies the script. A configure block needs no plugin:
--- `buildCache` and `toolchainManagement` are Gradle's own.
--- @return { plugins = table, entries = table, configure = table|nil }|nil
local function settings_plugins_of(config, owners)
  local plugins, entries = checked_plugin_set(config, "settingsPlugins", "settingsPluginClasspath",
                                              owners)
  local configure = config.settingsConfigure
  local configures = type(configure) == "table" and next(configure) ~= nil
  if #plugins == 0 and not configures then return nil end
  return { plugins = plugins, entries = entries, configure = configure }
end

return {
  MANIFEST = MANIFEST,
  config_of = config_of,
  gradle_version_of = gradle_version_of,
  jdk_version_of = jdk_version_of,
  jdk_for = jdk_for,
  layout_of = layout_of,
  checked_classpath = checked_classpath,
  entries_of_configurations = entries_of_configurations,
  checked_modules = checked_modules,
  checked_builds = checked_builds,
  composite_of = composite_of,
  project_name = project_name,
  checked_plugins = checked_plugins,
  settings_plugins_of = settings_plugins_of,
  validated = validated,
}
