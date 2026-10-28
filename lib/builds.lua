--- The included builds a project declares under `[toolchains.gradle.builds]`,
--- named and checked. Rendering lives in lib/composite.
local builds = {}

local module_graph = daukle.require("lib/modules")
local configurations = daukle.require("lib/configurations")

local KEYS = {
  gradlePlugins = true, release = true, configurations = true, logic = true, catalogs = true,
  sourceRoot = true, resourceRoot = true, testSourceRoot = true, testResourceRoot = true,
}
for index = 1, #configurations.all do KEYS[configurations.all[index].key] = true end

--- The keys a `[toolchains.gradle.builds.<dir>]` block takes.
builds.KEYS = KEYS

--- @implNote a build named after a project of the main build is refused by
--- Gradle in words naming a path, so it is refused here naming the build.
--- Every component of a module name is a project, implicit parents included.
local function project_names(declared, project_name)
  local names = { [project_name] = true }
  for index = 1, #declared do
    for component in string.gmatch(declared[index].name, "[^/]+") do names[component] = true end
  end
  return names
end

local PLUGIN_ENTRY_KEYS = { id = true, implementationClass = true }

local function unknown_plugin_entry_key_problem(label, entry)
  for key in pairs(entry) do
    if PLUGIN_ENTRY_KEYS[key] == nil then
      return '"' .. label .. '.' .. tostring(key) .. '" is not a key a plugin entry takes'
    end
  end
  return nil
end

--- @implNote an empty list or a single `{ id, implementationClass }` table has
--- no list entries, and would otherwise make the build a library build silently.
--- @return the entries, or nil and why they are refused
local function gradle_plugins_of(name, block)
  local entries = block.gradlePlugins
  if entries == nil then return {} end
  if type(entries) ~= "table" then
    return nil, '"builds.' .. name .. '.gradlePlugins" must be a list of entries, not a ' .. type(entries)
  end
  if #entries == 0 then
    return nil, '"builds.' .. name .. '.gradlePlugins" must be a non-empty list of'
                .. ' { id, implementationClass } entries'
  end
  for index = 1, #entries do
    local entry = entries[index]
    if type(entry) ~= "table" or type(entry.id) ~= "string"
       or type(entry.implementationClass) ~= "string" then
      return nil, '"builds.' .. name .. '.gradlePlugins[' .. index .. ']" needs an "id" and an'
                  .. ' "implementationClass"'
    end
    local problem = unknown_plugin_entry_key_problem('builds.' .. name .. '.gradlePlugins[' .. index .. ']',
                                                     entry)
    if problem ~= nil then return nil, problem end
  end
  return entries
end

local function unknown_key_problem(name, block)
  for key in pairs(block) do
    if KEYS[key] == nil then
      return '"builds.' .. name .. '.' .. tostring(key) .. '" is not a key an included build takes'
    end
  end
  return nil
end

local function sorted_names(table_of)
  local names = {}
  for name in pairs(table_of) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- Why one build's name or block is refused, or nil.
local function build_problem(name, block, taken, by_gradle_name)
  local problem = module_graph.problem_of(name)
  if problem ~= nil then
    return 'the included build "' .. name .. '" ' .. problem .. '. An included build is named'
           .. ' by its directory, with "/" between components'
  end
  if type(block) ~= "table" then
    return '"builds.' .. name .. '" must be a table, not a ' .. type(block)
  end
  problem = unknown_key_problem(name, block)
  if problem ~= nil then return problem end
  local gradle_name = (string.gsub(name, "/", "-"))
  if gradle_name == "buildSrc" then
    return 'the included build "' .. name .. '" is named "buildSrc" in Gradle, which Gradle'
           .. ' reserves for its implicit build: rename the directory, to "build-logic" for example'
  end
  if taken[gradle_name] then
    return 'the included build "' .. name .. '" is named "' .. gradle_name .. '" in Gradle,'
           .. ' which is also a project of this build'
  end
  if by_gradle_name[gradle_name] ~= nil then
    return 'the included builds "' .. by_gradle_name[gradle_name] .. '" and "' .. name
           .. '" are both named "' .. gradle_name .. '" in Gradle'
  end
  return nil
end

local function owners_or_problem(read)
  local owners = {}
  for index = 1, #read do
    local plugins = read[index].gradle_plugins
    for at = 1, #plugins do
      local id = plugins[at].id
      if owners[id] ~= nil then
        return nil, 'the plugin "' .. id .. '" is declared by both "' .. owners[id] .. '" and "'
                    .. read[index].name .. '"'
      end
      owners[id] = read[index].name
    end
  end
  return owners
end

--- The builds a config declares, read and named, or nil and why they are refused.
local function read_or_problem(config, declared, project_name)
  local blocks = config.builds
  if blocks == nil then return {} end
  if type(blocks) ~= "table" then
    return nil, '"builds" must be a table of included builds, not a ' .. type(blocks)
  end
  local taken = project_names(declared, project_name)
  local by_gradle_name = {}
  local out = {}
  local names = sorted_names(blocks)
  for index = 1, #names do
    local name = names[index]
    local block = blocks[name]
    local problem = build_problem(name, block, taken, by_gradle_name)
    if problem ~= nil then return nil, problem end
    local gradle_name = (string.gsub(name, "/", "-"))
    by_gradle_name[gradle_name] = name
    local gradle_plugins, plugins_problem = gradle_plugins_of(name, block)
    if plugins_problem ~= nil then return nil, plugins_problem end
    out[#out + 1] = { name = name, gradle_name = gradle_name, block = block, gradle_plugins = gradle_plugins }
  end
  local _, owners_problem = owners_or_problem(out)
  if owners_problem ~= nil then return nil, owners_problem end
  return out
end

--- Why `read` would refuse the builds a config declares, or nil, for the
--- migrator, which reports a refusal as a blocker.
function builds.read_problem(config, declared, project_name)
  local _, problem = read_or_problem(config, declared, project_name)
  return problem
end

--- @param manifest the parsed manifest, nil for a daukle.lua project
function builds.read(config, declared, project_name, manifest)
  module_graph.refuse_toolchain_keys_in_core_modules(manifest)
  local out, problem = read_or_problem(config, declared, project_name)
  if problem ~= nil then error(problem, 0) end
  return out
end

function builds.owners(read)
  local owners, problem = owners_or_problem(read)
  if problem ~= nil then error(problem, 0) end
  return owners
end

function builds.required(block, label, read)
  local wanted = block.requiresBuilds
  if wanted == nil then return {} end
  if type(wanted) ~= "table" then
    error('"' .. label .. '" must be a list of included build names, not a ' .. type(wanted), 0)
  end
  if #wanted == 0 and next(wanted) ~= nil then
    error('"' .. label .. '" must be a list of included build names, not a table of named keys',
          0)
  end
  local by_name = {}
  for index = 1, #read do by_name[read[index].name] = read[index] end
  local out = {}
  for index = 1, #wanted do
    local build = by_name[wanted[index]]
    if build == nil then
      error('"' .. label .. '" names "' .. tostring(wanted[index]) .. '", which is not an'
            .. ' included build', 0)
    end
    if #build.gradle_plugins > 0 then
      error('"' .. label .. '" names "' .. build.name .. '", which is a plugin build: a plugin'
            .. ' build is applied through "plugins", not depended on', 0)
    end
    out[#out + 1] = build.gradle_name
  end
  return out
end

return builds
