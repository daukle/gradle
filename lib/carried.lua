--- Build logic a project carries as code: the file a `logic` key names under
--- `daukle/gradle/logic/`, and where a build that carries any runs it from the
--- project's real directories (spec D-165, sections 4.4 and 7).
local carried = {}

local module_graph = daukle.require("lib/modules")
local composite = daukle.require("lib/composite")
local groovy = daukle.require("lib/groovy")

carried.DIRECTORY = "daukle/gradle/logic/"
carried.DERIVED = "build/daukle/gradle"
carried.REAL_ROOT = "../../.."
carried.ROOT_LINKS = "root-links.gradle"
carried.PLUGIN_CLASSPATH = "plugin-classpath.txt"

local GROOVY = ".gradle"
local KOTLIN = ".gradle.kts"
local SCRIPTS = "build/scripts/"
local OUTPUT = "build/out/"

--- The derived root's own top-level names, which no root link may take.
---
--- @implNote daukle.write writes IN PLACE, so a hard link under one of these
--- names would turn every write of it into a write of the user's own file.
--- `jars.gradle`, `discovered.txt` and `tools.gradle` are plugin.lua's and
--- tool_defaults' names, and `migrate-` prefixes every file the migrator writes.
carried.UNLINKED = {
  "build", "daukle", ".gradle", "settings.gradle", "settings.gradle.kts", ".daukle-generated",
  carried.ROOT_LINKS, carried.PLUGIN_CLASSPATH, "settings-plugins.gradle", composite.INCLUDED_DIR,
  "jars.gradle", "discovered.txt", "tools.gradle",
}
carried.UNLINKED_PREFIX = "migrate-"

local function starts_with(text, prefix)
  return string.sub(text, 1, #prefix) == prefix
end

local function ends_with(text, suffix)
  return string.sub(text, -#suffix) == suffix
end

function carried.is_kotlin(path)
  return type(path) == "string" and ends_with(path, KOTLIN)
end

local function is_logic_path(value)
  if not starts_with(value, carried.DIRECTORY) then return false end
  if not (ends_with(value, GROOVY) or ends_with(value, KOTLIN)) then return false end
  return module_graph.problem_of(string.sub(value, #carried.DIRECTORY + 1)) == nil
end

--- Why a `logic` value is refused, or nil.
function carried.problem_of(value, label)
  if value == nil then return nil end
  local wanted = '"' .. label .. '" must name a file under "' .. carried.DIRECTORY
                 .. '" ending ".gradle" or ".gradle.kts"'
  if type(value) ~= "string" then return wanted .. ", not a " .. type(value) end
  if not is_logic_path(value) then return wanted .. ', not "' .. value .. '"' end
  return nil
end

function carried.checked(value, label)
  local problem = carried.problem_of(value, label)
  if problem ~= nil then error(problem, 0) end
  return value
end

local function module_logic_paths(config)
  local paths = {}
  local blocks = type(config.modules) == "table" and config.modules or {}
  for name, block in pairs(blocks) do
    if type(block) == "table" and block.logic ~= nil then paths[name] = block.logic end
  end
  return paths
end

--- Every `logic` the main build names, as "label" -> path.
function carried.paths_of(config)
  local paths = {}
  if config.logic ~= nil then paths["logic"] = config.logic end
  for name, path in pairs(module_logic_paths(config)) do
    paths["modules." .. name .. ".logic"] = path
  end
  for name, block in pairs(type(config.builds) == "table" and config.builds or {}) do
    if type(block) == "table" and block.logic ~= nil then
      paths["builds." .. name .. ".logic"] = block.logic
    end
  end
  return paths
end

--- Whether the main build carries logic anywhere, which puts EVERY one of its
--- projects in the real-tree layout: a generated module directory would
--- collide with the root link of the real one (spec 7.1).
function carried.build_carries(config)
  return config.logic ~= nil or next(module_logic_paths(config)) ~= nil
end

local function build_carries_kotlin(config)
  if carried.is_kotlin(config.logic) then return true end
  for _, path in pairs(module_logic_paths(config)) do
    if carried.is_kotlin(path) then return true end
  end
  return false
end

--- Whether the plugin classpath moves into settings.gradle's own `buildscript {}`.
---
--- @implNote only there do a third-party plugin's Kotlin accessors compile
--- (spec 7.2). Generate may not acquire a jar, so settings.gradle reads the
--- paths from a list a task writes, measured on 7.6.4 and 9.6.0 with a
--- third-party extension accessor in a root and a module wrapper.
function carried.classpath_in_settings(config)
  local classpath = config.pluginClasspath
  return build_carries_kotlin(config) and type(classpath) == "table" and #classpath > 0
end

local function base_of(name)
  if name == nil then return "root" end
  return "modules/" .. name
end

--- The generated build file of the root project (name nil) or a module,
--- relative to its build's derived root.
function carried.script_of(name, logic)
  return SCRIPTS .. base_of(name) .. (carried.is_kotlin(logic) and KOTLIN or GROOVY)
end

--- The Groovy render a Kotlin wrapper applies.
function carried.rendered_of(name)
  return SCRIPTS .. base_of(name) .. ".rendered" .. GROOVY
end

--- The build directory, as a Groovy expression evaluated in the project.
function carried.build_directory_of(name)
  return "rootProject.file(" .. groovy.quoted(OUTPUT .. base_of(name)) .. ")"
end

--- The `file()` prefix that reaches a project's build root from the project's
--- directory: "." for a root, whose directory holds the root links, and one
--- ".." per component for a module in its real directory or an included build
--- under `included/`, since the layout's paths start with that name.
function carried.depth_of(name)
  if name == nil then return "." end
  local _, separators = string.gsub(name, "/", "")
  return ".." .. string.rep("/..", separators)
end

--- From an included build's derived root to its real directory.
function carried.real_directory_of_included(name)
  local _, separators = string.gsub(composite.path_of(name), "/", "")
  return carried.REAL_ROOT .. string.rep("/..", separators + 1) .. "/" .. name
end

local function file_exists(path)
  local directory, file = string.match(path, "^(.*)/([^/]+)$")
  for _, entry in ipairs(daukle.list(directory) or {}) do
    if entry.name == file and entry.kind ~= "directory" then return true end
  end
  return false
end

local function missing_message(label, path)
  return '"' .. label .. '" names "' .. path .. '", which does not exist'
end

--- @param carried_texts path -> text, which stands in for the files before
--- core has written them; nil reads every file
function carried.missing_problem(label, path, carried_texts)
  if carried_texts ~= nil and carried_texts[path] ~= nil then return nil end
  if file_exists(path) then return nil end
  return missing_message(label, path)
end

--- The carried text, verbatim.
function carried.text_of(label, path, carried_texts)
  if carried_texts ~= nil and carried_texts[path] ~= nil then return carried_texts[path] end
  if not file_exists(path) then error(missing_message(label, path), 0) end
  return daukle.read(path)
end

return carried
