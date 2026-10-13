local function quoted(text)
  return "'" .. text:gsub("\\", "/"):gsub("'", "\\'") .. "'"
end

return {
  quoted = quoted,
}
