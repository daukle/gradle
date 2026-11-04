--- A build's `gradle.properties` project properties, carried as the
--- project-wide `gradleProperties` key and passed to every Gradle run as `-P`
--- (spec D-224, 2026-11-04 corpus backlog design, section 2).
---
--- @implNote on the command line rather than in a generated file, because in the
--- real-tree layout the generated root project is the user's own directory.
local gradle_properties = {}

gradle_properties.KEY = "gradleProperties"

local GRADLE_PREFIX = "org.gradle."

--- @implNote ASCII only: core starts processes with the ANSI command line on
--- Windows, which Java then decodes in the host code page, so any other
--- character reaches Gradle as a different one.
local NOT_PORTABLE = " holds a character outside ASCII, which the Windows command line cannot pass to Gradle unchanged"
gradle_properties.NOT_PORTABLE = NOT_PORTABLE

function gradle_properties.is_portable(text)
  return not string.find(text, "[\128-\255]")
end

--- The checked table, or nil when the project declares none.
function gradle_properties.checked(config)
  local value = config[gradle_properties.KEY]
  if value == nil then return nil end
  if type(value) ~= "table" then
    error('"' .. gradle_properties.KEY .. '" must be a table of property name to value, not a ' .. type(value), 0)
  end
  for name, text in pairs(value) do
    local label = '"' .. gradle_properties.KEY .. '.' .. tostring(name) .. '"'
    if type(name) ~= "string" or name == "" then error(label .. " must be named by a non-empty string", 0) end
    if type(text) ~= "string" then error(label .. " must be a string, not a " .. type(text), 0) end
    if not gradle_properties.is_portable(text) then error(label .. NOT_PORTABLE, 0) end
    if string.sub(name, 1, #GRADLE_PREFIX) == GRADLE_PREFIX then
      error(label .. " is a Gradle setting, not a project property: it changes how Gradle runs", 0)
    end
  end
  return value
end

--- The `-P` arguments for every carried property, sorted by name.
function gradle_properties.arguments(config)
  local value = gradle_properties.checked(config) or {}
  local names = {}
  for name in pairs(value) do names[#names + 1] = name end
  table.sort(names)
  local arguments = {}
  for _, name in ipairs(names) do arguments[#arguments + 1] = "-P" .. name .. "=" .. value[name] end
  return arguments
end

local ESCAPED = { t = "\t", n = "\n", r = "\r", f = "\f" }

local function is_continued(line)
  local backslashes = string.match(line, "(\\*)$")
  return #backslashes % 2 == 1
end

--- The file's logical lines: comments and blanks dropped, a line ending in an
--- odd number of backslashes joined to the next with its leading blanks removed.
local function logical_lines(text)
  local lines, pending = {}, nil
  for raw in string.gmatch(text .. "\n", "([^\n]*)\n") do
    local line = string.gsub(string.gsub(raw, "\r$", ""), "^[ \t\f]+", "")
    if pending ~= nil then
      line = pending .. line
      pending = nil
    elseif line == "" or string.match(line, "^[#!]") then
      line = nil
    end
    if line ~= nil then
      if is_continued(line) then
        pending = string.sub(line, 1, -2)
      else
        lines[#lines + 1] = line
      end
    end
  end
  if pending ~= nil then lines[#lines + 1] = pending end
  return lines
end

local function utf8_of(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then return string.char(0xC0 | (code >> 6), 0x80 | (code & 0x3F)) end
  return string.char(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F))
end

--- One escape at `index` (the character after the backslash): its text and the next index.
local function unescaped_at(line, index)
  local character = string.sub(line, index, index)
  if character == "u" then
    local hex = string.match(line, "^%x%x%x%x", index + 1)
    if hex == nil then error("a \\u escape needs four hexadecimal digits", 0) end
    return utf8_of(tonumber(hex, 16)), index + 5
  end
  return ESCAPED[character] or character, index + 1
end

--- The key and value of one logical line, as `java.util.Properties` reads it.
local function key_and_value(line)
  local key, index = {}, 1
  while index <= #line do
    local character = string.sub(line, index, index)
    if character == "\\" then
      local text
      text, index = unescaped_at(line, index + 1)
      key[#key + 1] = text
    elseif character == "=" or character == ":" or string.match(character, "[ \t\f]") then
      break
    else
      key[#key + 1] = character
      index = index + 1
    end
  end
  index = string.match(line, "^[ \t\f]*()", index)
  if string.match(string.sub(line, index, index), "[=:]") then
    index = string.match(line, "^[ \t\f]*()", index + 1)
  end
  local value = {}
  while index <= #line do
    local character = string.sub(line, index, index)
    if character == "\\" then
      local text
      text, index = unescaped_at(line, index + 1)
      value[#value + 1] = text
    else
      value[#value + 1] = character
      index = index + 1
    end
  end
  return table.concat(key), table.concat(value)
end

--- Every entry of a properties file, in file order; a later key replaces an earlier one's value.
function gradle_properties.parse(text)
  local entries, at = {}, {}
  for _, line in ipairs(logical_lines(text)) do
    local key, value = key_and_value(line)
    if at[key] ~= nil then
      entries[at[key]].value = value
    else
      entries[#entries + 1] = { key = key, value = value }
      at[key] = #entries
    end
  end
  return entries
end

function gradle_properties.is_gradle_setting(key)
  return string.sub(key, 1, #GRADLE_PREFIX) == GRADLE_PREFIX
end

return gradle_properties
