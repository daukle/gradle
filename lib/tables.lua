--- The table helpers the migrator's modules share.
local tables = {}

function tables.append(target, source)
  for _, item in ipairs(source or {}) do target[#target + 1] = item end
  return target
end

--- A new list holding `first`'s values then `second`'s; either may be nil.
function tables.joined(first, second)
  return tables.append(tables.append({}, first), second)
end

function tables.shallow_copy(map)
  local copy = {}
  for key, value in pairs(map) do copy[key] = value end
  return copy
end

--- @implNote compared as text, because a model table can mix string and number keys.
function tables.sorted_keys(map)
  local keys = {}
  for key in pairs(map or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
  return keys
end

--- The entries of `map` whose key is in `keep`, and the rest.
function tables.split_keys(map, keep)
  local kept, rest = {}, {}
  for key, value in pairs(map) do
    if keep[key] then kept[key] = value else rest[key] = value end
  end
  return kept, rest
end

function tables.as_set(list)
  local set = {}
  for _, item in ipairs(list or {}) do set[item] = true end
  return set
end

function tables.deep_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return left == right end
  for key, value in pairs(left) do
    if not tables.deep_equal(value, right[key]) then return false end
  end
  for key in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

--- The first entry of `list` whose `name` is `name`, or nil.
function tables.named(list, name)
  for _, entry in ipairs(list or {}) do
    if entry.name == name then return entry end
  end
  return nil
end

return tables
