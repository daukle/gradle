local function quoted(text)
  return "'" .. text:gsub("\\", "/"):gsub("'", "\\'") .. "'"
end

local function src_dirs(paths, depth)
  if #paths == 0 then return "[]" end
  local rendered = {}
  for index = 1, #paths do
    rendered[index] = "new File(file(" .. quoted(depth) .. "), " .. quoted(paths[index]) .. ")"
  end
  return "[" .. table.concat(rendered, ", ") .. "]"
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
