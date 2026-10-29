--- The `verbatim` key: plain Gradle code one project carries inside
--- daukle.toml, in a single member named for its DSL (spec D-198, 4.1).
local verbatim = {}

local groovy = daukle.require("lib/groovy")
local build_file_kotlin = daukle.require("lib/build_file_kotlin")

local MEMBERS = { groovy = true, kotlin = true }

local function sorted_members(value)
  local members = {}
  for member in pairs(value) do members[#members + 1] = member end
  table.sort(members, function(left, right) return tostring(left) < tostring(right) end)
  return members
end

local function member_problem(value, label)
  local found
  for _, member in ipairs(sorted_members(value)) do
    if not MEMBERS[member] then
      return '"' .. label .. "." .. tostring(member) .. '" is not a member verbatim takes; it takes'
             .. " groovy or kotlin"
    end
    if found ~= nil then
      return '"' .. label .. '" holds both groovy and kotlin, and a project\'s code is in one of them'
    end
    found = member
  end
  if found == nil then return '"' .. label .. '" must hold groovy or kotlin', nil end
  return nil, found
end

local function text_problem(text, label)
  if type(text) ~= "string" then
    return '"' .. label .. '" must be a string of Gradle code, not a ' .. type(text)
  end
  if text == "" then return '"' .. label .. '" is empty: write the code, or remove it' end
  return nil
end

--- Why a `verbatim` value is refused, or nil, and the member it holds.
function verbatim.problem_of(value, label)
  if value == nil then return nil end
  if type(value) ~= "table" then
    return '"' .. label .. '" must be a table holding groovy or kotlin, not a ' .. type(value)
  end
  local problem, dsl = member_problem(value, label)
  if problem ~= nil then return problem end
  return text_problem(value[dsl], label .. "." .. dsl), dsl
end

--- Why an included build's `settingsVerbatim` is refused, or nil.
---
--- @implNote Kotlin needs a `settings.gradle.kts` wrapper, which only the main
--- build renders so far (spec D-187, 4.3).
function verbatim.included_settings_problem_of(value, label)
  local problem, dsl = verbatim.problem_of(value, label)
  if problem ~= nil then return problem end
  if dsl == "kotlin" then
    return '"' .. label .. '.kotlin" is Kotlin settings code in an included build, which daukle/gradle'
           .. " carries only in Groovy so far"
  end
  return nil
end

--- @return nil for no value, else { dsl, text, label }, `label` naming the member
function verbatim.checked(value, label)
  local problem, dsl = verbatim.problem_of(value, label)
  if problem ~= nil then error(problem, 0) end
  if value == nil then return nil end
  return { dsl = dsl, text = value[dsl], label = label .. "." .. dsl }
end

local function header_key(name)
  if string.match(name, "^[%w_-]+$") ~= nil then return name end
  return '"' .. name .. '"'
end

local function logic_problem(label, value, header)
  if type(value) ~= "string" then
    return '"' .. label .. '" is not a key since daukle/gradle 2.0.0: write the code in [' .. header .. "]"
  end
  local member = string.sub(value, -#".gradle.kts") == ".gradle.kts" and "kotlin" or "groovy"
  return '"' .. label .. '" names "' .. value .. '"; since daukle/gradle 2.0.0 the code lives in'
         .. " daukle.toml: put that file's text in [" .. header .. "] as " .. member .. " = '''...''',"
         .. " then delete the file"
end

local function catalog_problem(label, value, header)
  return '"' .. label .. '" names "' .. value .. '"; since daukle/gradle 2.0.0 a catalog lives in'
         .. " daukle.toml: put that file's tables in [" .. header .. ".versions] and its siblings"
         .. " (libraries, bundles, plugins), then delete the file"
end

--- The first path-valued catalog under `block.catalogs`, as a refusal, or nil.
local function retired_catalog_problem(block, label, header)
  local declared = type(block.catalogs) == "table" and block.catalogs or {}
  local names = {}
  for name in pairs(declared) do names[#names + 1] = name end
  table.sort(names, function(left, right) return tostring(left) < tostring(right) end)
  for _, name in ipairs(names) do
    if type(declared[name]) == "string" then
      return catalog_problem(label .. "." .. tostring(name), declared[name], header .. "." .. header_key(name))
    end
  end
  return nil
end

local function sorted_blocks(blocks)
  local names = {}
  for name, block in pairs(type(blocks) == "table" and blocks or {}) do
    if type(block) == "table" then names[#names + 1] = name end
  end
  table.sort(names, function(left, right) return tostring(left) < tostring(right) end)
  return names
end

--- The first key `daukle/gradle@2.0.0` retired that a config still sets, as
--- a refusal naming its replacement, or nil.
---
--- @implNote checked before every other key, so a retired key meets this copy
--- and never the generic "is not a key" of the block it sits in.
--- @param instance the toolchain instance, which the replacement's header names
function verbatim.retired_problem(config, instance)
  local scope = "toolchains." .. header_key(instance) .. "."
  if config.logic ~= nil then return logic_problem("logic", config.logic, scope .. "verbatim") end
  for _, family in ipairs({ "modules", "builds" }) do
    for _, name in ipairs(sorted_blocks(config[family])) do
      local block = config[family][name]
      if block.logic ~= nil then
        return logic_problem(family .. "." .. name .. ".logic", block.logic,
                             scope .. family .. "." .. header_key(name) .. ".verbatim")
      end
    end
  end
  local catalog = retired_catalog_problem(config, "catalogs", scope .. "catalogs")
  if catalog ~= nil then return catalog end
  for _, name in ipairs(sorted_blocks(config.builds)) do
    catalog = retired_catalog_problem(config.builds[name], "builds." .. name .. ".catalogs",
                                      scope .. "builds." .. header_key(name) .. ".catalogs")
    if catalog ~= nil then return catalog end
  end
  return nil
end

--- The line a render writes ahead of the carried text, which reports the
--- code on every Gradle run as coverage owed (spec 4.6).
function verbatim.warn_line(checked)
  local message = "daukle/gradle: " .. checked.label .. " is plain Gradle code no daukle key covers yet"
  if checked.dsl == "kotlin" then return "logger.warn(" .. build_file_kotlin.quoted(message) .. ")" end
  return "logger.warn(" .. groovy.quoted(message) .. ")"
end

return verbatim
