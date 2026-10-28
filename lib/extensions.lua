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
  -- not `configuration`: `dependencyInsight { configuration = '...' }` would then read as a marker
  filesOf = function(text)
    return "configurations[" .. groovy.quoted(text) .. "]"
  end,
}

local MARKER_NAMES = '"file", "buildOutput", "env" or "filesOf"'

--[[ daukle's own token is the one core credential this plugin does not declare,
     so core scrubs it from Gradle's environment and the rendered `?: ''` would
     hand the build an empty string with nothing saying why. Refused by name
     instead. GITHUB_TOKEN is declared and does reach Gradle; see AUTHORING.md. ]]
local REFUSED_ENV = { DAUKLE_TOKEN = true }

local function is_list(value)
  return #value > 0
end

--- `jvmArgs = []`, which Lua alone cannot tell from a header-only table such
--- as `[toolchainManagement.jvm.javaRepositories]` that must stay a block.
--- Core marks every TOML array, api 5 (D-176).
local function is_empty_array(value)
  return next(value) == nil and getmetatable(value) == "daukle.array"
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

local function is_call(value)
  return type(value) == "table" and value.call ~= nil
end

--- @return "values", "calls" or "blocks" for a list entry, nil for what no list can hold
local function entry_kind(entry)
  local kind = type(entry)
  if kind == "string" or kind == "number" or kind == "boolean" then return "values" end
  if kind ~= "table" then return nil end
  if is_call(entry) then return "calls" end
  if read_marker(entry, "") ~= nil then return "values" end
  return "blocks"
end

--- @return "assignment", "call", "block", or the kind of a list's first entry
local function value_kind(value)
  if type(value) ~= "table" then return "assignment" end
  if is_call(value) then return "call" end
  if read_marker(value, "") ~= nil then return "assignment" end
  if is_list(value) then return entry_kind(value[1]) end
  if is_empty_array(value) then return "values" end
  return "block"
end

local function is_block(value)
  local kind = value_kind(value)
  return kind == "block" or kind == "blocks"
end

local function is_call_kind(value)
  local kind = value_kind(value)
  return kind == "call" or kind == "calls"
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

--- A call argument or a plain list entry: a scalar or a marker, never a block.
local function plain_value_problem(value, path)
  if type(value) == "table" and value_kind(value) ~= "assignment" then
    return '"' .. path .. '" must be a string, number, boolean or one of ' .. MARKER_NAMES .. ", not a block"
  end
  return assignment_problem(value, path)
end

local CALL_KEYS = { call = true, body = true }

local function call_problem(value, path)
  for key in pairs(value) do
    if not CALL_KEYS[key] then
      return '"' .. path .. '" mixes "call" with the key "' .. tostring(key) .. '": a call holds only its'
             .. ' arguments and an optional "body"'
    end
  end
  local arguments = value.call
  if type(arguments) ~= "table" or (next(arguments) ~= nil and not is_list(arguments)) then
    return '"' .. path .. '.call" must be a list of arguments'
  end
  for index = 1, #arguments do
    local problem = plain_value_problem(arguments[index], path .. ".call[" .. index .. "]")
    if problem ~= nil then return problem end
  end
  if value.body == nil then return nil end
  if type(value.body) ~= "table" or not is_block(value.body) then
    return '"' .. path .. '.body" must be a block: it is the closure the call is given'
  end
  return body_problem(value.body, path .. ".body")
end

local function list_mix_problem(value, path)
  local first = entry_kind(value[1])
  for index = 2, #value do
    if entry_kind(value[index]) ~= first then
      return '"' .. path .. '" mixes blocks, method calls and plain values in one list: a list holds one of them'
    end
  end
  return nil
end

local ENTRY_PROBLEM = {
  values = plain_value_problem,
  calls = call_problem,
  blocks = block_problem,
}

local function list_problem(value, path)
  if next(value) == nil then return nil end
  local problem = list_mix_problem(value, path)
  if problem ~= nil then return problem end
  local check = ENTRY_PROBLEM[entry_kind(value[1])]
  if check == nil then
    return '"' .. path .. '[1]" is a ' .. type(value[1]) .. ", which no Gradle value can be spelled as"
  end
  for entry = 1, #value do
    problem = check(value[entry], path .. "[" .. entry .. "]")
    if problem ~= nil then return problem end
  end
  return nil
end

local function value_problem(value, path)
  local kind = value_kind(value)
  if kind == "assignment" then return assignment_problem(value, path) end
  if kind == "call" then return call_problem(value, path) end
  if kind == "block" then return block_problem(value, path) end
  return list_problem(value, path)
end

local function is_identifier(key)
  return string.match(key, "^[%a_][%w_]*$") ~= nil
end

--- Why a key cannot be written into the build, or nil (D-175).
---
--- @implNote a block name that is not an identifier, such as a container
--- element `my-mod`, is written quoted, which Gradle 7.6.4 and 9.6.0 read as the
--- same call; a call or an assignment has no quoted spelling Groovy accepts.
local function key_problem(key, value, path)
  local where = '"' .. path .. "." .. key .. '"'
  if is_block(value) then
    if key == "" or string.find(key, "[%c\\]") ~= nil then
      return where .. " is not a block name: it is written into the build quoted, which cannot"
             .. " carry a backslash or a control character"
    end
    return nil
  end
  if is_identifier(key) then return nil end
  if is_call_kind(value) then
    return where .. " is not a method name: it is written into the build as a Gradle identifier,"
           .. " so letters, digits and underscores only"
  end
  return where .. " is not a property name: it is written into the build as a Gradle identifier,"
         .. " so letters, digits and underscores only"
end

function body_problem(body, path)
  if is_list(body) then return '"' .. path .. '" is a list where a block was expected' end
  for _, key in ipairs(sorted_keys(body)) do
    if type(key) ~= "string" then return '"' .. path .. '" mixes list entries with named keys' end
    local problem = key_problem(key, body[key], path)
    if problem ~= nil then return problem end
    problem = value_problem(body[key], path .. "." .. key)
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
    if type(value) ~= "table" or found ~= nil or not is_block(value) then
      return '"' .. label .. '.' .. key .. '" must be a block: ' .. label .. ' names the extension a'
             .. " plugin registered, and its keys are what that extension takes"
    end
  end
  return body_problem(configure, label)
end

local render_body

local function render_block(lines, indent, name, body, depth)
  if not is_identifier(name) then name = groovy.quoted(name) end
  lines[#lines + 1] = indent .. name .. " {"
  render_body(lines, indent .. "  ", body, depth)
  lines[#lines + 1] = indent .. "}"
end

local function render_literal(value, depth)
  local kind = type(value)
  if kind == "string" then return groovy.quoted(value) end
  if kind == "number" then return groovy_number(value) end
  if kind == "boolean" then return tostring(value) end
  local marker = read_marker(value, "")
  return MARKERS[marker](value[marker], depth)
end

local function render_literals(entries, depth)
  local rendered = {}
  for index = 1, #entries do rendered[index] = render_literal(entries[index], depth) end
  return rendered
end

local function render_assignment(lines, indent, key, value, depth)
  if value_kind(value) == "values" then
    lines[#lines + 1] = indent .. key .. " = [" .. table.concat(render_literals(value, depth), ", ") .. "]"
  else
    lines[#lines + 1] = indent .. key .. " = " .. render_literal(value, depth)
  end
end

local function render_call(lines, indent, key, call, depth)
  local head = indent .. key .. "(" .. table.concat(render_literals(call.call, depth), ", ") .. ")"
  if call.body == nil then
    lines[#lines + 1] = head
    return
  end
  lines[#lines + 1] = head .. " {"
  render_body(lines, indent .. "  ", call.body, depth)
  lines[#lines + 1] = indent .. "}"
end

local function render_each(render, lines, indent, key, value, depth)
  if is_list(value) and not is_call(value) then
    for entry = 1, #value do render(lines, indent, key, value[entry], depth) end
  else
    render(lines, indent, key, value, depth)
  end
end

--- @implNote sorted, values before calls before blocks: pairs order is
--- undefined, and a nested closure may read a property set before it.
function render_body(lines, indent, body, depth)
  local values, calls, blocks = {}, {}, {}
  for key in pairs(body) do
    local group = values
    if is_block(body[key]) then group = blocks elseif is_call_kind(body[key]) then group = calls end
    group[#group + 1] = key
  end
  table.sort(values)
  table.sort(calls)
  table.sort(blocks)

  for _, key in ipairs(values) do render_assignment(lines, indent, key, body[key], depth) end
  for _, key in ipairs(calls) do render_each(render_call, lines, indent, key, body[key], depth) end
  for _, key in ipairs(blocks) do render_each(render_block, lines, indent, key, body[key], depth) end
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
