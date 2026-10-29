--- Configurations a project declares itself, `declaredConfigurations.<name>`:
--- created by the render before carried code runs, wired with `extendsFrom`,
--- and given project dependencies and artifacts (spec D-203).
local declared_configurations = {}

local configurations = daukle.require("lib/configurations")
local groovy = daukle.require("lib/groovy")
local tables = daukle.require("lib/tables")

local KEYS = {
  extendsFrom = true, extendedBy = true, requires = true, artifacts = true,
  canBeResolved = true, canBeConsumed = true, transitive = true,
}
local FLAGS = { "canBeResolved", "canBeConsumed", "transitive" }
local REQUIRE_KEYS = { module = true, configuration = true }
local NAME_PATTERN = "^[%a_][%w_]*$"

--- Gradle's own names for the configurations every `java` project has, which a
--- declaration would collide with.
local GRADLE_OWN = {
  compileClasspath = true, runtimeClasspath = true, testCompileClasspath = true,
  testRuntimeClasspath = true, runtimeElements = true, apiElements = true,
}

local function size(map)
  local count = 0
  for _ in pairs(map) do count = count + 1 end
  return count
end

local function is_modelled(name)
  if GRADLE_OWN[name] then return true end
  for _, row in ipairs(configurations.all) do
    if row.render == name then return true end
  end
  return false
end

local function checked_names(value, label)
  if value == nil then return {} end
  if type(value) ~= "table" or #value ~= size(value) then
    error('"' .. label .. '" must be a list of configuration names', 0)
  end
  for index, name in ipairs(value) do
    if type(name) ~= "string" or string.match(name, NAME_PATTERN) == nil then
      error('"' .. label .. '[' .. index .. ']" must be a configuration name: letters, digits and'
            .. ' underscores only', 0)
    end
  end
  return value
end

local function checked_require(entry, label, modules)
  local require = type(entry) == "string" and { module = entry } or entry
  if type(require) ~= "table" then
    error('"' .. label .. '" must be a module name or { module, configuration }, not a ' .. type(entry), 0)
  end
  for key in pairs(require) do
    if not REQUIRE_KEYS[key] then
      error('"' .. label .. '.' .. tostring(key) .. '" is not a key a requires entry takes', 0)
    end
  end
  if type(require.module) ~= "string" or not modules[require.module] then
    error('"' .. label .. '" names no module this project declares: ' .. tostring(require.module), 0)
  end
  if require.configuration ~= nil and (type(require.configuration) ~= "string"
                                       or string.match(require.configuration, NAME_PATTERN) == nil) then
    error('"' .. label .. '.configuration" must be a configuration name', 0)
  end
  return require
end

local function checked_requires(value, label, modules)
  if value == nil then return {} end
  if type(value) ~= "table" or #value ~= size(value) then
    error('"' .. label .. '" must be a list of modules', 0)
  end
  local requires = {}
  for index, entry in ipairs(value) do
    requires[index] = checked_require(entry, label .. '[' .. index .. ']', modules)
  end
  return requires
end

local function checked_flags(block, label)
  local flags = {}
  for _, flag in ipairs(FLAGS) do
    local value = block[flag]
    if value ~= nil and type(value) ~= "boolean" then
      error('"' .. label .. '.' .. flag .. '" must be true or false, not a ' .. type(value), 0)
    end
    flags[flag] = value
  end
  return flags
end

local function checked_one(name, block, label, modules)
  if type(name) ~= "string" or string.match(name, NAME_PATTERN) == nil then
    error('"' .. label .. '" is not a configuration name: letters, digits and underscores only', 0)
  end
  if is_modelled(name) then
    error('"' .. label .. '" is a configuration Gradle or this toolchain already provides, so it'
          .. ' cannot be declared again', 0)
  end
  if type(block) ~= "table" then error('"' .. label .. '" must be a block, not a ' .. type(block), 0) end
  for key in pairs(block) do
    if not KEYS[key] then
      error('"' .. label .. '.' .. tostring(key) .. '" is not a key a declared configuration takes', 0)
    end
  end
  return {
    name = name,
    extends_from = checked_names(block.extendsFrom, label .. ".extendsFrom"),
    extended_by = checked_names(block.extendedBy, label .. ".extendedBy"),
    requires = checked_requires(block.requires, label .. ".requires", modules),
    artifacts = checked_names(block.artifacts, label .. ".artifacts"),
    flags = checked_flags(block, label),
  }
end

--- The configurations `block` declares, checked and sorted by name.
---
--- @param scope the manifest path of `block`, so a refusal names a key that exists
--- @param module_names the project's declared module names, which `requires` may name
function declared_configurations.read(block, scope, module_names)
  local value = (block or {}).declaredConfigurations
  if value == nil then return {} end
  local label = scope .. "declaredConfigurations"
  if type(value) ~= "table" then
    error('"' .. label .. '" must be a table of blocks keyed by configuration name, not a ' .. type(value), 0)
  end
  local modules = tables.as_set(module_names or {})
  local declared = {}
  for _, name in ipairs(tables.sorted_keys(value)) do
    declared[#declared + 1] = checked_one(name, value[name], label .. "." .. tostring(name), modules)
  end
  return declared
end

local function create_line(declared)
  local flags = {}
  for _, flag in ipairs(FLAGS) do
    if declared.flags[flag] ~= nil then flags[#flags + 1] = flag .. " = " .. tostring(declared.flags[flag]) end
  end
  if #flags == 0 then return "  create(" .. groovy.quoted(declared.name) .. ")" end
  return "  create(" .. groovy.quoted(declared.name) .. ") { " .. table.concat(flags, "; ") .. " }"
end

--- The `configurations {}` block creating and wiring every declaration, or no lines.
function declared_configurations.configurations_lines(declared)
  if #declared == 0 then return {} end
  local lines = { "configurations {" }
  for _, one in ipairs(declared) do lines[#lines + 1] = create_line(one) end
  for _, one in ipairs(declared) do
    local quoted = groovy.quoted(one.name)
    for _, base in ipairs(one.extends_from) do
      lines[#lines + 1] = "  getByName(" .. quoted .. ").extendsFrom(getByName(" .. groovy.quoted(base) .. "))"
    end
    for _, user in ipairs(one.extended_by) do
      lines[#lines + 1] = "  getByName(" .. groovy.quoted(user) .. ").extendsFrom(getByName(" .. quoted .. "))"
    end
  end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  return lines
end

--- The lines inside `dependencies {}` putting each required project on its declaration.
---
--- @param project_path turns a module name into its Gradle path
function declared_configurations.dependency_lines(declared, project_path)
  local lines = {}
  for _, one in ipairs(declared) do
    for _, require in ipairs(one.requires) do
      local target = "path: " .. groovy.quoted(project_path(require.module))
      if require.configuration ~= nil then
        target = target .. ", configuration: " .. groovy.quoted(require.configuration)
      end
      lines[#lines + 1] = "  add(" .. groovy.quoted(one.name) .. ", project(" .. target .. "))"
    end
  end
  return lines
end

--- The `artifacts {}` block, or no lines.
---
--- @implNote `tasks.named` fails configuration loudly for a task nothing
--- registers, measured on Gradle 7.6.4 and 9.6.0 (spec D-203, section 6).
function declared_configurations.artifacts_lines(declared)
  local lines = {}
  for _, one in ipairs(declared) do
    for _, task in ipairs(one.artifacts) do
      lines[#lines + 1] = "  add(" .. groovy.quoted(one.name) .. ", tasks.named(" .. groovy.quoted(task) .. "))"
    end
  end
  if #lines == 0 then return {} end
  table.insert(lines, 1, "artifacts {")
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  return lines
end

return declared_configurations
