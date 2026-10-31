--- A walked extension's file collection (`$files`), compared as the classpath
--- rows compare theirs: as a multiset of entries rather than a list of paths.
---
--- @implNote the generated build puts a project's outputs under another build
--- directory and takes its jars from daukle's cache, so an entry under the
--- project's build directory is compared by its place inside it, and one
--- outside the build root, which the dump leaves absolute, by its file name.
--- Order is not compared: a derived view (`allOutputs`, `classesDirs`) lists
--- the same directories in the order plugins registered them, and where order
--- decides which class loads, the classpath rows already compare it.
local migrate_file_collections = {}

local function is_absolute(path)
  return string.match(path, "^%a:/") ~= nil or string.sub(path, 1, 1) == "/"
end

local function normalized(path, build_dir)
  if type(path) ~= "string" then return tostring(path) end
  if build_dir ~= nil then
    if path == build_dir then return "<build>" end
    local prefix = build_dir .. "/"
    if string.sub(path, 1, #prefix) == prefix then return "<build>/" .. string.sub(path, #prefix + 1) end
  end
  if is_absolute(path) then return "<file>/" .. (string.match(path, "([^/]+)$") or path) end
  return path
end

local function entries_of(files, build_dir)
  local entries = {}
  for index, path in ipairs(files) do entries[index] = normalized(path, build_dir) end
  return entries
end

local function counts_of(entries)
  local counts = {}
  for _, entry in ipairs(entries) do counts[entry] = (counts[entry] or 0) + 1 end
  return counts
end

--- Appends `{ path = <path>.<index>, entry, side }` for each entry of
--- `entries` the other side lacks, `entry` as that side's dump wrote it.
local function append_unmatched(entries, files, other, side, path, out)
  local available = counts_of(other)
  for index, entry in ipairs(entries) do
    if (available[entry] or 0) > 0 then
      available[entry] = available[entry] - 1
    else
      out[#out + 1] = { path = path .. "." .. index, entry = tostring(files[index]), side = side }
    end
  end
end

--- @param directories { old = <the old project's build directory>, new = <the generated one's> }, either nil
function migrate_file_collections.differences(old_files, new_files, path, directories, out)
  local old = entries_of(old_files, directories.old)
  local new = entries_of(new_files, directories.new)
  append_unmatched(old, old_files, new, "the old build", path, out)
  append_unmatched(new, new_files, old, "the build daukle/gradle generates", path, out)
  return out
end

return migrate_file_collections
