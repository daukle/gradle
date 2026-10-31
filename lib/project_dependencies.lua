--- A module's `projectDependencies`: another module of the build on one of the
--- configurations `lib/configurations` keys, where core's `requires` is
--- `implementation` alone (spec D-211).
local project_dependencies = {}

local configurations = daukle.require("lib/configurations")
local declared_configurations = daukle.require("lib/declared_configurations")
local groovy = daukle.require("lib/groovy")
local tables = daukle.require("lib/tables")

local REQUIRES_KEY = "classpath"

local function row_of(key)
  for _, row in ipairs(configurations.all) do
    if row.key == key then return row end
  end
  return nil
end

local function checked_key(key, label)
  if key == REQUIRES_KEY then
    error('"' .. label .. '" is `implementation`, which core\'s `requires` in [modules.<name>] already says', 0)
  end
  local row = row_of(key)
  if row == nil then
    error('"' .. label .. '" is not a configuration key: it takes the keys a module puts jars on,'
          .. ' such as compileOnly, runtimeOnly or testClasspath', 0)
  end
  return row
end

local function refuse_itself(requires, label, own_name)
  for index, require in ipairs(requires) do
    if require.module == own_name then
      error('"' .. label .. '[' .. index .. ']" names the module itself', 0)
    end
  end
end

--- The module's project dependencies, checked.
---
--- @param scope the manifest path of `block`, so a refusal names a key that exists
--- @return { { row = <the lib/configurations row>, requires = { { module, configuration? } } } }, by key
function project_dependencies.read(block, scope, module_names, own_name)
  local value = (block or {}).projectDependencies
  if value == nil then return {} end
  local label = scope .. "projectDependencies"
  if type(value) ~= "table" then
    error('"' .. label .. '" must be a table keyed by configuration, not a ' .. type(value), 0)
  end
  local modules = tables.as_set(module_names or {})
  local read = {}
  for _, key in ipairs(tables.sorted_keys(value)) do
    local key_label = label .. "." .. tostring(key)
    local row = checked_key(key, key_label)
    local requires = declared_configurations.checked_requires(value[key], key_label, modules)
    refuse_itself(requires, key_label, own_name)
    read[#read + 1] = { row = row, requires = requires }
  end
  return read
end

--- Whether an entry sits on a configuration only `java-library` has.
function project_dependencies.needs_java_library(read)
  for _, one in ipairs(read or {}) do
    if one.row.library and #one.requires > 0 then return true end
  end
  return false
end

--- The lines inside `dependencies {}`, one per entry.
function project_dependencies.lines(read, project_path)
  local lines = {}
  for _, one in ipairs(read or {}) do
    for _, require in ipairs(one.requires) do
      local target = groovy.quoted(project_path(require.module))
      if require.configuration ~= nil then
        target = "path: " .. target .. ", configuration: " .. groovy.quoted(require.configuration)
      end
      lines[#lines + 1] = "  " .. one.row.render .. " project(" .. target .. ")"
    end
  end
  return lines
end

return project_dependencies
