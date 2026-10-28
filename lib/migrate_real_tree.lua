--- The paths of a carrying build's generated model, mapped to where the old
--- build has them, so a comparison sees only what the carried code changes.
---
--- @implNote Gradle pins `rootDir`, the root project's `projectDir` and
--- `settingsDir` to the derived root, and the dump writes a path relative to
--- that root, or absolute when it lies outside, as a module's real directory
--- does. A carrying render also moves each project's build directory under
--- `build/out/` (spec 7.1). Both models are therefore rewritten relative to
--- the REAL root, and the generated build directories back to `<project>/build`;
--- any other difference still compares as one.
local migrate_real_tree = {}

local OUTPUT = "build/out/"
local ROOT_OUTPUT = OUTPUT .. "root"
local MODULES_OUTPUT = OUTPUT .. "modules/"
local OLD_OUTPUT = "build"

local function starts_at(text, prefix)
  return text == prefix or string.sub(text, 1, #prefix + 1) == prefix .. "/"
end

local function replaced_prefix(text, prefix, replacement)
  if not starts_at(text, prefix) then return nil end
  local rest = string.sub(text, #prefix + 1)
  if replacement == "." then
    rest = string.sub(rest, 2)
    if rest == "" then return "." end
    return rest
  end
  return replacement .. rest
end

local function relative_to(text, root)
  return replaced_prefix(text, root, ".") or text
end

local function output_mapped(text, modules)
  local mapped = replaced_prefix(text, ROOT_OUTPUT, OLD_OUTPUT)
  if mapped ~= nil then return mapped end
  for _, name in ipairs(modules) do
    mapped = replaced_prefix(text, MODULES_OUTPUT .. name, name .. "/" .. OLD_OUTPUT)
    if mapped ~= nil then return mapped end
  end
  return text
end

local function mapped_copy(value, map_string)
  if type(value) == "string" then return map_string(value) end
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do copy[key] = mapped_copy(item, map_string) end
  return copy
end

--- The old model, every absolute path under its real root made relative.
function migrate_real_tree.old(model, real_root)
  return mapped_copy(model, function(text) return relative_to(text, real_root) end)
end

--- The generated model, its derived root read as the real root, every path
--- under that made relative, and each build directory moved back.
---
--- @param modules the module names of the build, whose directories are their names
function migrate_real_tree.generated(model, derived_root, real_root, modules)
  return mapped_copy(model, function(text)
    local real = replaced_prefix(text, derived_root, real_root) or text
    return output_mapped(relative_to(real, real_root), modules)
  end)
end

return migrate_real_tree
