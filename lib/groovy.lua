local function quoted(text)
  return "'" .. text:gsub("\\", "/"):gsub("'", "\\'") .. "'"
end

--- A `srcDirs(...)` call that ADDS the roots, never an assignment.
---
--- @implNote `srcDirs = [...]` replaces the directory a plugin added to the set
--- before this block runs, and with it the task dependency that directory
--- carried: `antlr`'s generated parser was then never compiled (D-178).
local function src_dirs(paths, depth)
  local rendered = {}
  for index = 1, #paths do
    rendered[index] = "new File(file(" .. quoted(depth) .. "), " .. quoted(paths[index]) .. ")"
  end
  return "srcDirs(" .. table.concat(rendered, ", ") .. ")"
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
