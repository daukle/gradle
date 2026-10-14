--- The included builds a project declares under `[toolchains.gradle.builds]`,
--- named and checked. Rendering lives in lib/composite.
local builds = {}

local module_graph = daukle.require("lib/modules")
local configurations = daukle.require("lib/configurations")

local KEYS = {
  gradlePlugins = true, release = true,
  sourceRoot = true, resourceRoot = true, testSourceRoot = true, testResourceRoot = true,
}
for index = 1, #configurations.all do KEYS[configurations.all[index].key] = true end

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

local function gradle_plugins_of(name, block)
  local entries = block.gradlePlugins
  if entries == nil then return {} end
  if type(entries) ~= "table" then
    error('"builds.' .. name .. '.gradlePlugins" must be a list of entries, not a '
          .. type(entries), 0)
  end
  for index = 1, #entries do
    local entry = entries[index]
    if type(entry) ~= "table" or type(entry.id) ~= "string"
       or type(entry.implementationClass) ~= "string" then
      error('"builds.' .. name .. '.gradlePlugins[' .. index .. ']" needs an "id" and an'
            .. ' "implementationClass"', 0)
    end
  end
  return entries
end

--- @implNote core reads only `requires` in its `[modules.<n>]` and hands every
--- other key on unread, so only this plugin can see a misplaced one there.
local function refuse_requires_builds_in_core_modules(manifest)
  local modules = manifest ~= nil and manifest.modules or nil
  if type(modules) ~= "table" then return end
  for name, block in pairs(modules) do
    if type(block) == "table" and block.requiresBuilds ~= nil then
      error('"modules.' .. name .. '.requiresBuilds" is in core\'s "[modules.' .. name .. ']",'
            .. ' which this toolchain never reads: write it under "[toolchains.gradle.modules.'
            .. name .. ']"', 0)
    end
  end
end

local function refuse_an_unknown_key(name, block)
  for key in pairs(block) do
    if KEYS[key] == nil then
      error('"builds.' .. name .. '.' .. tostring(key) .. '" is not a key an included build'
            .. ' takes', 0)
    end
  end
end

local function sorted_names(table_of)
  local names = {}
  for name in pairs(table_of) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- @param manifest the parsed manifest, nil for a daukle.lua project
function builds.read(config, declared, project_name, manifest)
  refuse_requires_builds_in_core_modules(manifest)
  local blocks = config.builds
  if blocks == nil then return {} end
  if type(blocks) ~= "table" then
    error('"builds" must be a table of included builds, not a ' .. type(blocks), 0)
  end
  local taken = project_names(declared, project_name)
  local by_gradle_name = {}
  local out = {}
  local names = sorted_names(blocks)
  for index = 1, #names do
    local name = names[index]
    local problem = module_graph.problem_of(name)
    if problem ~= nil then
      error('the included build "' .. name .. '" ' .. problem .. '. An included build is named'
            .. ' by its directory, with "/" between components', 0)
    end
    local block = blocks[name]
    if type(block) ~= "table" then
      error('"builds.' .. name .. '" must be a table, not a ' .. type(block), 0)
    end
    refuse_an_unknown_key(name, block)
    local gradle_name = (string.gsub(name, "/", "-"))
    if gradle_name == "buildSrc" then
      error('the included build "' .. name .. '" is named "buildSrc" in Gradle, which Gradle'
            .. ' reserves for its implicit build: rename the directory, to "build-logic" for'
            .. ' example', 0)
    end
    if taken[gradle_name] then
      error('the included build "' .. name .. '" is named "' .. gradle_name .. '" in Gradle,'
            .. ' which is also a project of this build', 0)
    end
    if by_gradle_name[gradle_name] ~= nil then
      error('the included builds "' .. by_gradle_name[gradle_name] .. '" and "' .. name
            .. '" are both named "' .. gradle_name .. '" in Gradle', 0)
    end
    by_gradle_name[gradle_name] = name
    out[#out + 1] = { name = name, gradle_name = gradle_name, block = block,
                      gradle_plugins = gradle_plugins_of(name, block) }
  end
  builds.owners(out)
  return out
end

function builds.owners(read)
  local owners = {}
  for index = 1, #read do
    local plugins = read[index].gradle_plugins
    for at = 1, #plugins do
      local id = plugins[at].id
      if owners[id] ~= nil then
        error('the plugin "' .. id .. '" is declared by both "' .. owners[id] .. '" and "'
              .. read[index].name .. '"', 0)
      end
      owners[id] = read[index].name
    end
  end
  return owners
end

function builds.required(block, label, read)
  local wanted = block.requiresBuilds
  if wanted == nil then return {} end
  if type(wanted) ~= "table" then
    error('"' .. label .. '" must be a list of included build names, not a ' .. type(wanted), 0)
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
