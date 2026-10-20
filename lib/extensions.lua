local groovy = daukle.require("lib/groovy")
local tables = daukle.require("lib/tables")

--- @implNote sorted, so a refusal names the same key on every run.
local sorted_keys = tables.sorted_keys

--[[ A value that cannot be spelled by its Lua type, written as a one-key table
     rather than a magic prefix inside a string, because a prefix is a thing a
     real value will one day collide with. Every spelling below was run on
     Gradle 8.13 and 9.6.0 before it was written down.

     `file` and `buildOutput` exist as a PAIR because a path in a hand-written
     build means one of two things and daukle moved the project directory out
     from under both: `file('assets')` meant the project root, which the derived
     directory sits three levels below and a module's directory at least four, and
     `file('build/libs/x.jar')` meant the build directory, which Gradle still
     owns. Measured across this tree's build files, roughly half of each, so
     collapsing them into one marker is silently wrong for the other half.

     `file` therefore takes the same depth the source roots do: a project-wide
     configure block is rendered into every module's file, so a marker that
     carried the derived root's own depth would resolve one directory too high
     in every one of them. ]]
local MARKERS = {
  file = function(text, depth)
    return "new File(file(" .. groovy.quoted(depth) .. "), " .. groovy.quoted(text) .. ")"
  end,
  buildOutput = function(text)
    return "layout.buildDirectory.file(" .. groovy.quoted(text) .. ").get().asFile"
  end,
  env = function(text)
    return "System.getenv(" .. groovy.quoted(text) .. ") ?: ''"
  end,
}

local MARKER_NAMES = '"file", "buildOutput" or "env"'

--[[ daukle's own token is the one core credential this plugin does not declare,
     so core scrubs it from Gradle's environment and the rendered `?: ''` would
     hand the build an empty string with nothing saying why. Refused by name
     instead. GITHUB_TOKEN is declared and does reach Gradle; see AUTHORING.md. ]]
local REFUSED_ENV = { DAUKLE_TOKEN = true }

local function is_list(value)
  return #value > 0
end

--[[ Core carries the manifest through JSON and pushes every number as a Lua
     float, so a plugin cannot tell the TOML `7` from the TOML `7.0`: both
     arrive as 7.0, and `tostring` would write a Groovy BigDecimal where a
     Gradle property almost always wants an int. An integral value is therefore
     written as an integer, which is right for the one of the two spellings
     anybody uses and wrong for a property that genuinely wants 7.0. ]]
local function groovy_number(value)
  if value % 1 == 0 and value >= -9007199254740992 and value <= 9007199254740992 then
    return string.format("%d", value)
  end
  return tostring(value)
end

--- The marker key of a one-key table, or nil when the table is a nested block,
--- and why the table can be neither, or nil.
local function read_marker(value, path)
  local found, keys = nil, 0
  for key in pairs(value) do
    keys = keys + 1
    if MARKERS[key] ~= nil then found = key end
  end
  if found == nil then return nil end
  if keys > 1 then
    return found, '"' .. path .. '" mixes the marker "' .. found .. '" with other keys: a marker holds'
                  .. ' exactly one of ' .. MARKER_NAMES
  end
  if type(value[found]) ~= "string" then
    return found, '"' .. path .. "." .. found .. '" must be a string, not a ' .. type(value[found])
  end
  if found == "env" and REFUSED_ENV[value[found]] then
    return found, '"' .. path .. '" names ' .. value[found] .. ", which daukle keeps to itself: it is"
                  .. " daukle's own credential and no build input"
  end
  return found
end

local function is_block(value, path)
  return type(value) == "table" and (read_marker(value, path)) == nil
end

local body_problem

local function block_problem(body, path)
  if type(body) ~= "table" then
    return '"' .. path .. '" must be a block or a value, not a ' .. type(body)
  end
  return body_problem(body, path)
end

local function assignment_problem(value, path)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then return nil end
  if kind == "table" then
    local _, problem = read_marker(value, path)
    return problem
  end
  return '"' .. path .. '" is a ' .. kind .. ", which no Gradle value can be spelled as"
end

local function nested_problem(value, path)
  if not is_list(value) then return block_problem(value, path) end
  for entry = 1, #value do
    local problem = block_problem(value[entry], path .. "[" .. entry .. "]")
    if problem ~= nil then return problem end
  end
  return nil
end

function body_problem(body, path)
  if is_list(body) then return '"' .. path .. '" is a list where a block was expected' end
  for _, key in ipairs(sorted_keys(body)) do
    local value = body[key]
    if type(key) ~= "string" then return '"' .. path .. '" mixes list entries with named keys' end
    local item_path = path .. "." .. key
    local problem
    if is_block(value, item_path) then
      problem = nested_problem(value, item_path)
    else
      problem = assignment_problem(value, item_path)
    end
    if problem ~= nil then return problem end
  end
  return nil
end

--- Why `configuration` would refuse this tree, or nil: the reason rather than
--- a raise, for the migrator, which reports a refusal as a blocker.
--- @param label the manifest key the tree came from, so a refusal names the key
--- the user wrote: "configure" for a project, "settingsConfigure" for settings
--- @implNote a top-level entry must be a block: a bare value would land at the
--- top level of the build file, where Groovy reads it as a project property and
--- Gradle fails with a name that is nobody's.
local function configuration_problem(configure, label)
  label = label or "configure"
  if configure == nil then return nil end
  if type(configure) ~= "table" then
    return '"' .. label .. '" must be a table of extension blocks, not a ' .. type(configure)
  end
  for _, key in ipairs(sorted_keys(configure)) do
    local value = configure[key]
    if type(key) ~= "string" then
      return '"' .. label .. '" is a list where a table of extension blocks was expected'
    end
    local found, problem = nil, nil
    if type(value) == "table" then found, problem = read_marker(value, label .. "." .. key) end
    if problem ~= nil then return problem end
    if type(value) ~= "table" or found ~= nil then
      return '"' .. label .. '.' .. key .. '" must be a block: ' .. label .. ' names the extension a'
             .. " plugin registered, and its keys are what that extension takes"
    end
  end
  return body_problem(configure, label)
end

local render_body

local function render_block(lines, indent, name, body, depth)
  lines[#lines + 1] = indent .. name .. " {"
  render_body(lines, indent .. "  ", body, depth)
  lines[#lines + 1] = indent .. "}"
end

local function render_assignment(lines, indent, key, value, depth)
  local kind = type(value)
  if kind == "string" then
    lines[#lines + 1] = indent .. key .. " = " .. groovy.quoted(value)
  elseif kind == "number" then
    lines[#lines + 1] = indent .. key .. " = " .. groovy_number(value)
  elseif kind == "boolean" then
    lines[#lines + 1] = indent .. key .. " = " .. tostring(value)
  else
    local marker = read_marker(value, key)
    lines[#lines + 1] = indent .. key .. " = " .. MARKERS[marker](value[marker], depth)
  end
end

--[[ Keys are emitted sorted, values before blocks, because Lua's pairs order is
     undefined and a generated file a test compares byte for byte may not depend
     on it. Values first is not only cosmetic: a nested closure that reads a
     property of its own extension sees one that was already set. ]]
function render_body(lines, indent, body, depth)
  local values, blocks = {}, {}
  for key in pairs(body) do
    if is_block(body[key], key) then
      blocks[#blocks + 1] = key
    else
      values[#values + 1] = key
    end
  end
  table.sort(values)
  table.sort(blocks)

  for index = 1, #values do
    local key = values[index]
    render_assignment(lines, indent, key, body[key], depth)
  end
  for index = 1, #blocks do
    local key = blocks[index]
    local value = body[key]
    if is_list(value) then
      for entry = 1, #value do render_block(lines, indent, key, value[entry], depth) end
    else
      render_block(lines, indent, key, value, depth)
    end
  end
end

--- @param label as `configuration_problem` takes it
local function configuration(configure, depth, label)
  local problem = configuration_problem(configure, label)
  if problem ~= nil then error(problem, 0) end
  if configure == nil then return {} end
  local lines = {}
  render_body(lines, "", configure, depth)
  return lines
end

return {
  configuration = configuration,
  configuration_problem = configuration_problem,
}
