--- Build logic a project carries as code: the file a `logic` key names under
--- `daukle/<instance>/logic/`, and where a build that carries any runs it from the
--- project's real directories (spec D-165, sections 4.4 and 7).
local carried = {}

local module_graph = daukle.require("lib/modules")
local composite = daukle.require("lib/composite")
local groovy = daukle.require("lib/groovy")

local REAL_ROOT_OF_ROOT = "../../.."
carried.ROOT_LINKS = "root-links.gradle"
carried.PLUGIN_CLASSPATH = "plugin-classpath.txt"
carried.SETTINGS_PLUGINS = "settings-plugins.gradle"
carried.JARS_SCRIPT = "jars.gradle"
carried.DISCOVERY_REPORT = "discovered.txt"
carried.TOOL_DEFAULTS_SCRIPT = "tools.gradle"
carried.MIGRATE_PREFIX = "migrate-"

--- What the root links script placed, inside a derived root's `build/`, which
--- is never linked.
carried.LINK_RECORD = "build/daukle-root-links.txt"

local GROOVY = ".gradle"
local KOTLIN = ".gradle.kts"
local SCRIPTS = "build/scripts/"
local OUTPUT = "build/out/"

--- The derived root's own top-level names, which no root link may take: every
--- owner that writes one takes its name from here.
---
--- @implNote daukle.write writes IN PLACE, so a hard link under one of these
--- names would turn every write of it into a write of the user's own file.
--- `buildSrc` is never linked because Gradle builds a `buildSrc` it finds in
--- the settings directory, writing into the user's tree.
carried.UNLINKED = {
  "build", "daukle", ".gradle", "settings.gradle", "settings.gradle.kts", ".daukle-generated",
  "buildSrc", carried.ROOT_LINKS, carried.PLUGIN_CLASSPATH, carried.SETTINGS_PLUGINS,
  carried.JARS_SCRIPT, carried.DISCOVERY_REPORT, carried.TOOL_DEFAULTS_SCRIPT,
  composite.INCLUDED_DIR,
}

local function starts_with(text, prefix)
  return string.sub(text, 1, #prefix) == prefix
end

local function ends_with(text, suffix)
  return string.sub(text, -#suffix) == suffix
end

function carried.is_kotlin(path)
  return type(path) == "string" and ends_with(path, KOTLIN)
end

--- The directory an instance's `logic` files live in, below its committed
--- `daukle/<instance>/`, which is where core writes a migrator's files.
function carried.directory_of(instance)
  return "daukle/" .. instance .. "/logic/"
end

--- An instance's derived root, relative to the project.
function carried.derived_of(instance)
  return "build/daukle/" .. instance
end

--- The instance's own directory below the project, from `context.root`,
--- which is `../../..` for the project root and `../../../<dir>` otherwise.
function carried.dir_of_root(root)
  if root == nil or root == REAL_ROOT_OF_ROOT then return nil end
  return string.sub(root, #REAL_ROOT_OF_ROOT + 2)
end

--- The derived root as a project's real directory reaches it, from the
--- build's real root: one `..` per component of the instance's `dir`.
function carried.derived_from_real_root(root, instance)
  local climb = ""
  for _ in string.gmatch(carried.dir_of_root(root) or "", "[^/]+") do climb = climb .. "../" end
  return climb .. carried.derived_of(instance)
end

local function is_logic_path(value, directory)
  if not starts_with(value, directory) then return false end
  if not (ends_with(value, GROOVY) or ends_with(value, KOTLIN)) then return false end
  return module_graph.problem_of(string.sub(value, #directory + 1)) == nil
end

--- Why a `logic` value is refused, or nil.
function carried.problem_of(value, label, instance)
  if value == nil then return nil end
  local directory = carried.directory_of(instance)
  local wanted = '"' .. label .. '" must name a file under "' .. directory
                 .. '" ending ".gradle" or ".gradle.kts"'
  if type(value) ~= "string" then return wanted .. ", not a " .. type(value) end
  if not is_logic_path(value, directory) then return wanted .. ', not "' .. value .. '"' end
  return nil
end

function carried.checked(value, label, instance)
  local problem = carried.problem_of(value, label, instance)
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

--- Every `logic` path mapped to empty text, for a discovery's bare baseline.
---
--- @implNote that baseline leaves the plugins out, and carried code naming a
--- plugin's task or extension would fail to configure without them.
function carried.empty_texts(config)
  local texts = {}
  for _, path in pairs(carried.paths_of(config)) do texts[path] = "" end
  return texts
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
--- @param root the build's real root from its derived root, `context.root`
function carried.real_directory_of_included(name, root)
  local _, separators = string.gsub(composite.path_of(name), "/", "")
  return string.rep("../", separators + 1) .. root .. "/" .. name
end

local function file_exists(path)
  local directory, file = string.match(path, "^(.*)/([^/]+)$")
  for _, entry in ipairs(daukle.list(directory) or {}) do
    if entry.name == file and entry.kind ~= "directory" then return true end
  end
  return false
end

--- Whether a carrying build linked this derived root to the real tree.
---
--- @implNote decided by the record the links script writes rather than by
--- looking for links: core lists a hard link as a plain file.
--- @param derived_root the derived root, relative to the project
function carried.is_linked(derived_root)
  return file_exists(derived_root .. "/" .. carried.LINK_RECORD)
end

--- Refuses to render a build without logic into a derived root that a
--- carrying build linked to the real tree.
---
--- @implNote daukle.write opens a path for writing in place, so a generated
--- `build.gradle` would be written through the hard link into the user's own
--- build file.
--- @param derived_root the derived root, relative to the project
function carried.refuse_a_linked_root(derived_root)
  local record = derived_root .. "/" .. carried.LINK_RECORD
  if carried.is_linked(derived_root) then
    error('"' .. derived_root .. '" holds links to the project\'s own files, which a build'
          .. ' carrying logic placed (listed in "' .. record .. '"), and a build without'
          .. ' "logic" would write through them: run "daukle clean" first', 0)
  end
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
