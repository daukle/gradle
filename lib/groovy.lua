local function quoted(text)
  return "'" .. text:gsub("\\", "/"):gsub("'", "\\'") .. "'"
end

local function src_dir(root, depth)
  if type(root) == "table" then return "layout.buildDirectory.dir(" .. quoted(root.buildOutput) .. ")" end
  return "new File(file(" .. quoted(depth) .. "), " .. quoted(root) .. ")"
end

--- The depth of a project rendered in its own real directory, where a root can be
--- the very directory Gradle's convention already put in the set.
local REAL_TREE_DEPTH = "."

--- A `srcDirs(...)` call that ADDS the roots, never an assignment.
---
--- @implNote `srcDirs = [...]` replaces the directory a plugin added to the set
--- before this block runs, and with it the task dependency that directory
--- carried: `antlr`'s generated parser was then never compiled (D-178). In the
--- real tree a root already in the set is skipped: the set keeps one entry per
--- call, so `processResources` copied every resource twice and failed on it.
local function src_dirs(paths, depth)
  local rendered = {}
  for index = 1, #paths do rendered[index] = src_dir(paths[index], depth) end
  local roots = table.concat(rendered, ", ")
  if depth == REAL_TREE_DEPTH then
    return "srcDirs(*[" .. roots .. "].findAll { !(it in srcDirs) })"
  end
  return "srcDirs(" .. roots .. ")"
end

local function file_list(paths, indent)
  local rendered = {}
  for index = 1, #paths do
    rendered[index] = indent .. quoted(paths[index])
  end
  return table.concat(rendered, ",\n")
end

return {
  quoted = quoted,
  src_dirs = src_dirs,
  file_list = file_list,
}
