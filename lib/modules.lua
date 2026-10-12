--- The module graph this toolchain renders, read from what core hands a
--- callback rather than from the manifest text.
---
--- @implNote core publishes `{ name, requires }` per module in both the
--- generate and the task context. A project with no `[modules]` yields an
--- empty list, which is what keeps the single-project rendering untouched.

local modules = {}

local function refuse_a_nested_name(name)
  if string.find(name, ":", 1, true) ~= nil or string.find(name, "/", 1, true) ~= nil then
    error('the module "' .. name .. '" holds ":" or "/", and this toolchain models a flat'
          .. ' module list: a nested module is not generated', 0)
  end
end

--- @param context a generate or task context
--- @return { { name = string, requires = { string } } } in manifest order
function modules.declared(context)
  local declared = context.modules or {}
  local out = {}
  for index = 1, #declared do
    local entry = declared[index]
    refuse_a_nested_name(entry.name)
    out[#out + 1] = { name = entry.name, requires = entry.requires or {} }
  end
  return out
end

return modules
