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

return modules
