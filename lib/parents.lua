--- The `[toolchains.gradle.root]` and `[toolchains.gradle.parents.<name>]`
--- blocks: the plugins and configure blocks of a multi-project build's root
--- project and of each implicit parent, which the project-wide keys never
--- reach, since those are `subprojects {}` (D-168). Checking the plugin lists
--- against the classpath is lib/validation's.
local parents = {}

local module_graph = daukle.require("lib/modules")
local tables = daukle.require("lib/tables")

local KEYS = { plugins = true, configure = true }

--- The keys a root or parent block takes.
parents.KEYS = KEYS

local function checked_block(value, label)
  if type(value) ~= "table" then error('"' .. label .. '" must be a table, not a ' .. type(value), 0) end
  for key in pairs(value) do
    if KEYS[key] == nil then
      error('"' .. label .. '.' .. tostring(key) .. '" is not a key a root or parent block takes:'
            .. ' it takes plugins and configure', 0)
    end
  end
  return value
end

local function declared_names(declared)
  local names = {}
  for _, module in ipairs(declared) do names[module.name] = true end
  return names
end

local function checked_parent_name(name, label, declared, implicit)
  if declared_names(declared)[name] then
    error('"' .. label .. '" names a declared module, whose keys belong in [toolchains.gradle.modules.'
          .. name .. ']', 0)
  end
  if not implicit[name] then
    error('"' .. label .. '" names no implicit parent of the declared modules: a parent is a directory'
          .. ' that holds a module and is not one', 0)
  end
end

--- Every root or parent block the config holds, shape-checked.
---
--- @return { { name = <the parent's name, nil for the root>, label, block } }, the root first, then
---         the parents by name
function parents.blocks(config, declared)
  local named = config.parents
  if named ~= nil and type(named) ~= "table" then
    error('"parents" must be a table of blocks, not a ' .. type(named), 0)
  end
  local found = {}
  if config.root == nil and (named == nil or next(named) == nil) then return found end
  if #declared == 0 then
    error('"root" and "parents" need declared modules: in a single-project build the root is the'
          .. ' project, and the project-wide keys are its own', 0)
  end
  if config.root ~= nil then found[1] = { label = "root", block = checked_block(config.root, "root") } end
  local implicit = tables.as_set(module_graph.undeclared_parents(declared))
  for _, name in ipairs(tables.sorted_keys(named or {})) do
    local label = "parents." .. name
    checked_parent_name(name, label, declared, implicit)
    found[#found + 1] = { name = name, label = label, block = checked_block(named[name], label) }
  end
  return found
end

return parents
