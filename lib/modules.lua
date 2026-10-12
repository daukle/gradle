--- The module graph this toolchain renders, read from what core hands a
--- callback rather than from the manifest text.

local modules = {}

local NESTING_CHARACTERS = { ":", "/", "\\" }

local function holds_a_nesting_character(name)
  for _, character in ipairs(NESTING_CHARACTERS) do
    if string.find(name, character, 1, true) ~= nil then
      return true
    end
  end
  return false
end

--- @implNote a backslash is refused too because the renderer turns every
--- backslash into a slash, which would smuggle a nested include past the guard.
local function refuse_a_nested_name(name)
  if holds_a_nesting_character(name) then
    error('the module "' .. name .. '" holds ":", "/" or "\\", and this toolchain models a'
          .. ' flat module list: a nested module is not generated', 0)
  end
end

--- @implNote core publishes `{ name, requires }` per module in both the
--- generate and the task context, and `requires` is always a list. A project
--- with no `[modules]` yields an empty list, which is what keeps the
--- single-project rendering untouched.
--- @param context a generate or task context
--- @return { { name = string, requires = { string } } } in manifest order
function modules.declared(context)
  local declared = context.modules or {}
  local out = {}
  for index = 1, #declared do
    local entry = declared[index]
    refuse_a_nested_name(entry.name)
    out[#out + 1] = { name = entry.name, requires = entry.requires }
  end
  return out
end

local DEFAULT_SUFFIX = {
  sourceRoot = "src/main/java",
  resourceRoot = "src/main/resources",
  testSourceRoot = "src/test/java",
  testResourceRoot = "src/test/resources",
}

--- @param label where the key really lives, when that is not the key itself: a
--- module's fault names "modules.<name>.<key>" so the refusal names something
--- the manifest actually holds
function modules.string_key(block, key, fallback, label)
  local value = block[key]
  if value == nil then return fallback end
  if type(value) ~= "string" then
    error('"' .. (label or key) .. '" must be a string, not a ' .. type(value), 0)
  end
  return value
end

--- The source layout of one module, or of the project itself when `name` is nil.
---
--- @implNote a module's roots default to its own name, which is the shape 117
--- of this tree's 185 subproject build files rely on: they declare nothing and
--- take the convention. One function for both so the four defaults live in one
--- table: a second copy drifts the first time a fifth root is added.
function modules.layout_of(name, block)
  block = block or {}
  local prefix = name ~= nil and (name .. "/") or ""
  local scope = name ~= nil and ("modules." .. name .. ".") or ""
  local function dirs_for(key)
    return { modules.string_key(block, key, prefix .. DEFAULT_SUFFIX[key], scope .. key) }
  end
  return {
    main = { java = dirs_for("sourceRoot"), resources = dirs_for("resourceRoot") },
    test = { java = dirs_for("testSourceRoot"), resources = dirs_for("testResourceRoot") },
  }
end

local MODULE_KEYS = {
  sourceRoot = true, resourceRoot = true, testSourceRoot = true, testResourceRoot = true,
  main = true, classpath = true, testClasspath = true,
}

--- The toolchain's own per-module blocks, checked against the graph.
function modules.blocks_of(config, declared)
  local blocks = config.modules
  if blocks == nil then return {} end
  if type(blocks) ~= "table" then
    error('"modules" must be a table of per-module blocks, not a ' .. type(blocks), 0)
  end
  local known = {}
  for index = 1, #declared do known[declared[index].name] = true end
  for name in pairs(blocks) do
    if known[name] == nil then
      error('"modules.' .. tostring(name) .. '" names no module this project declares: a'
            .. ' module is declared in "[modules]" and configured here', 0)
    end
  end
  return blocks
end

--- @implNote a module key left at the top level would apply to every module at
--- once, silently. Same rule and same reason as daukle/cmake's "targets".
function modules.refuse_a_module_key_project_wide(config, declared)
  if #declared == 0 then return end
  for key in pairs(MODULE_KEYS) do
    if config[key] ~= nil then
      error('"' .. key .. '" belongs to a module and this project declares modules, so it has'
            .. ' to live in "[toolchains.gradle.modules.<name>]": a project-wide "' .. key
            .. '" would apply to every module at once', 0)
    end
  end
end

return modules
