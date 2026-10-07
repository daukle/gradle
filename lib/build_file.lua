--- Rendering the build Gradle reads.
---
--- The whole point of this file is in two lines of what it writes: the source
--- sets point back at the real tree, and every dependency is an absolute path
--- into daukle's artifact cache. So there is NO `repositories {}` block and
--- Gradle resolves nothing. Resolution is daukle/maven's, which is the end goal
--- rather than a convenience.

local build_file = {}

--[[ The derived directory is build/daukle/gradle/, so the project root is three
     levels up. It is load bearing and fails SILENTLY when wrong: with the
     sourceSets block removed, Gradle resolves src/main/java against the project
     directory, finds nothing, compiles nothing and exits 0 on `classes`. That
     is why the tests assert on compiled output and never on this text. ]]
local ROOT = "../../.."

local function groovy_string(text)
  return "'" .. text:gsub("\\", "/"):gsub("'", "\\'") .. "'"
end

local function src_dirs(paths)
  if #paths == 0 then return "[]" end
  local rendered = {}
  for index = 1, #paths do
    rendered[index] = "new File(file(" .. groovy_string(ROOT) .. "), " .. groovy_string(paths[index])
                      .. ")"
  end
  return "[" .. table.concat(rendered, ", ") .. "]"
end

local function file_list(paths, indent)
  local rendered = {}
  for index = 1, #paths do
    rendered[index] = indent .. groovy_string(paths[index])
  end
  return table.concat(rendered, ",\n")
end

local function source_set(name, java_dirs, resource_dirs)
  return "  " .. name .. " {\n"
         .. "    java      { srcDirs = " .. src_dirs(java_dirs) .. " }\n"
         .. "    resources { srcDirs = " .. src_dirs(resource_dirs) .. " }\n"
         .. "  }"
end

--[[ A value that cannot be spelled by its Lua type, written as a one-key table
     rather than a magic prefix inside a string, because a prefix is a thing a
     real value will one day collide with. Every spelling below was run on
     Gradle 8.13 and 9.6.0 before it was written down.

     `file` and `buildOutput` exist as a PAIR because a path in a hand-written
     build means one of two things and daukle moved the project directory out
     from under both: `file('assets')` meant the project root, which is now
     three levels up, and `file('build/libs/x.jar')` meant the build directory,
     which Gradle still owns. Measured across this tree's build files, roughly
     half of each, so collapsing them into one marker is silently wrong for the
     other half. ]]
local MARKERS = {
  file = function(text)
    return "new File(file(" .. groovy_string(ROOT) .. "), " .. groovy_string(text) .. ")"
  end,
  buildOutput = function(text)
    return "layout.buildDirectory.file(" .. groovy_string(text) .. ").get().asFile"
  end,
  env = function(text)
    return "System.getenv(" .. groovy_string(text) .. ") ?: ''"
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

--- The marker key of a one-key table, or nil when the table is a nested block.
local function marker_of(value, path)
  local found, keys = nil, 0
  for key in pairs(value) do
    keys = keys + 1
    if MARKERS[key] ~= nil then found = key end
  end
  if found == nil then return nil end
  if keys > 1 then
    error('"' .. path .. '" mixes the marker "' .. found .. '" with other keys: a marker holds'
          .. ' exactly one of ' .. MARKER_NAMES, 0)
  end
  if type(value[found]) ~= "string" then
    error('"' .. path .. "." .. found .. '" must be a string, not a ' .. type(value[found]), 0)
  end
  if found == "env" and REFUSED_ENV[value[found]] then
    error('"' .. path .. '" names ' .. value[found] .. ", which daukle keeps to itself: it is"
          .. " daukle's own credential and no build input", 0)
  end
  return found
end

local render_body

local function render_block(lines, indent, name, body, path)
  if type(body) ~= "table" then
    error('"' .. path .. '" must be a block or a value, not a ' .. type(body), 0)
  end
  lines[#lines + 1] = indent .. name .. " {"
  render_body(lines, indent .. "  ", body, path)
  lines[#lines + 1] = indent .. "}"
end

local function render_assignment(lines, indent, key, value, path)
  local kind = type(value)
  if kind == "string" then
    lines[#lines + 1] = indent .. key .. " = " .. groovy_string(value)
  elseif kind == "number" then
    lines[#lines + 1] = indent .. key .. " = " .. groovy_number(value)
  elseif kind == "boolean" then
    lines[#lines + 1] = indent .. key .. " = " .. tostring(value)
  elseif kind == "table" then
    local marker = marker_of(value, path)
    lines[#lines + 1] = indent .. key .. " = " .. MARKERS[marker](value[marker])
  else
    error('"' .. path .. '" is a ' .. kind .. ", which no Gradle value can be spelled as", 0)
  end
end

--[[ Keys are emitted sorted, values before blocks, because Lua's pairs order is
     undefined and a generated file a test compares byte for byte may not depend
     on it. Values first is not only cosmetic: a nested closure that reads a
     property of its own extension sees one that was already set. ]]
function render_body(lines, indent, body, path)
  if is_list(body) then
    error('"' .. path .. '" is a list where a block was expected', 0)
  end
  local values, blocks = {}, {}
  for key in pairs(body) do
    if type(key) ~= "string" then
      error('"' .. path .. '" mixes list entries with named keys', 0)
    end
    local value = body[key]
    if type(value) == "table" and marker_of(value, path .. "." .. key) == nil then
      blocks[#blocks + 1] = key
    else
      values[#values + 1] = key
    end
  end
  table.sort(values)
  table.sort(blocks)

  for index = 1, #values do
    local key = values[index]
    render_assignment(lines, indent, key, body[key], path .. "." .. key)
  end
  for index = 1, #blocks do
    local key = blocks[index]
    local value = body[key]
    if is_list(value) then
      for entry = 1, #value do
        render_block(lines, indent, key, value[entry], path .. "." .. key .. "[" .. entry .. "]")
      end
    else
      render_block(lines, indent, key, value, path .. "." .. key)
    end
  end
end

--- Every `configure` block, as Groovy text. Pure, so `generate` can run it to
--- refuse a bad tree before anything is acquired.
function build_file.configuration(configure)
  if configure == nil then return {} end
  if type(configure) ~= "table" then
    error('"configure" must be a table of extension blocks, not a ' .. type(configure), 0)
  end
  local lines = {}
  for key in pairs(configure) do
    if type(key) ~= "string" then
      error('"configure" is a list where a table of extension blocks was expected', 0)
    end
    --[[ A bare value here would land at the top level of the build file, where
         Groovy reads it as a project property and Gradle fails with a name that
         is nobody's: "configure" names an extension, so its entries are blocks. ]]
    if type(configure[key]) ~= "table" or marker_of(configure[key], "configure." .. key) ~= nil then
      error('"configure.' .. key .. '" must be a block: configure names the extension a plugin'
            .. " registered, and its keys are what that extension takes", 0)
    end
  end
  render_body(lines, "", configure, "configure")
  return lines
end

--- @param layout  { main = {java, resources}, test = {java, resources} }
--- @param jars    { compile = {path...}, test = {path...}, plugin = {path...} }
--- @param options { release, main, plugins, configure }
function build_file.render(layout, jars, options)
  local lines = {
    "// Generated by daukle/gradle. Do not edit: daukle.toml is yours, this is not.",
    "// Every dependency below is a path into daukle's artifact cache, pinned by",
    "// sha256 before it got there, which is why this build declares no repository.",
    "",
  }

  --[[ buildscript must come first in a Groovy build file and `plugins {}` must
       precede every other statement, so this block order is fixed rather than
       following the manifest's. `apply plugin:` rather than an id in the
       `plugins {}` block: that block resolves from the Plugin Portal by id, and
       Gradle resolving anything is the one property this design gives up
       nothing else to keep. ]]
  if #jars.plugin > 0 then
    lines[#lines + 1] = "buildscript {"
    lines[#lines + 1] = "  dependencies {"
    lines[#lines + 1] = "    classpath files(\n" .. file_list(jars.plugin, "      ") .. "\n    )"
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "plugins { id 'java' }"
  lines[#lines + 1] = ""

  for index = 1, #options.plugins do
    lines[#lines + 1] = "apply plugin: " .. groovy_string(options.plugins[index].id)
  end
  if #options.plugins > 0 then lines[#lines + 1] = "" end

  lines[#lines + 1] = "sourceSets {"
  lines[#lines + 1] = source_set("main", layout.main.java, layout.main.resources)
  lines[#lines + 1] = source_set("test", layout.test.java, layout.test.resources)
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "dependencies {"
  if #jars.compile > 0 then
    lines[#lines + 1] = "  implementation files(\n" .. file_list(jars.compile, "    ") .. "\n  )"
  end
  if #jars.test > 0 then
    lines[#lines + 1] = "  testImplementation files(\n" .. file_list(jars.test, "    ") .. "\n  )"
  end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""

  if options.release ~= nil then
    lines[#lines + 1] = "java {"
    lines[#lines + 1] = "  sourceCompatibility = JavaVersion.toVersion("
                        .. groovy_string(options.release) .. ")"
    lines[#lines + 1] = "  targetCompatibility = JavaVersion.toVersion("
                        .. groovy_string(options.release) .. ")"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
  end

  --[[ Pinned rather than inherited, and this is not housekeeping: java-utils'
       own build carries a comment recording that Gradle 8.11.1 read its sources
       as Cp1252 on Windows where 7.6.4 read them as UTF-8, so an unpinned
       encoding makes the compiled bytes a property of whichever build ran. It
       matters more in a generated file than in a hand-written one, because the
       user cannot see this one. ]]
  lines[#lines + 1] = "tasks.withType(JavaCompile).configureEach { options.encoding = 'UTF-8' }"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "test { useJUnitPlatform() }"

  local configuration = build_file.configuration(options.configure)
  for index = 1, #configuration do
    --[[ One blank line before each top-level block, which is every line this
         returns at indent zero that is not a closing brace. ]]
    if configuration[index]:sub(1, 1) ~= " " and configuration[index] ~= "}" then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = configuration[index]
  end

  if options.main ~= nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "tasks.register('daukleRun', JavaExec) {"
    lines[#lines + 1] = "  classpath = sourceSets.main.runtimeClasspath"
    lines[#lines + 1] = "  mainClass = " .. groovy_string(options.main)
    lines[#lines + 1] = "}"
  end

  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

--- Without this Gradle names the project after its directory, which would be
--- "gradle".
function build_file.settings(name)
  return "// Generated by daukle/gradle. Do not edit.\n"
         .. "rootProject.name = " .. groovy_string(name) .. "\n"
end

return build_file
