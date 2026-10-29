--- Build logic a project carries as code, in its `verbatim` key, and where a
--- build that carries any runs it from the project's real directories (spec
--- D-165, sections 4.4 and 7; spec D-198, 4.2).
local carried = {}

local composite = daukle.require("lib/composite")
local groovy = daukle.require("lib/groovy")
local verbatim = daukle.require("lib/verbatim")

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
--- the settings directory, writing into the user's tree, and `.kotlin`
--- because the Kotlin Gradle Plugin 2.x writes its session files there.
carried.UNLINKED = {
  "build", "daukle", ".gradle", ".kotlin", "settings.gradle", "settings.gradle.kts", ".daukle-generated",
  "buildSrc", carried.ROOT_LINKS, carried.PLUGIN_CLASSPATH, carried.SETTINGS_PLUGINS,
  carried.JARS_SCRIPT, carried.DISCOVERY_REPORT, carried.TOOL_DEFAULTS_SCRIPT,
  composite.INCLUDED_DIR,
}

--- @param checked what `verbatim.checked` returned, nil for no carried code
function carried.is_kotlin(checked)
  return checked ~= nil and checked.dsl == "kotlin"
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

local function module_verbatims(config)
  local values = {}
  local blocks = type(config.modules) == "table" and config.modules or {}
  for name, block in pairs(blocks) do
    if type(block) == "table" and block.verbatim ~= nil then values[name] = block.verbatim end
  end
  return values
end

--- The main build's root project's carried code, checked, or nil.
function carried.root_of(config)
  return verbatim.checked(config.verbatim, "verbatim")
end

--- A module's carried code, checked, or nil.
function carried.module_of(config, name)
  local block = (type(config.modules) == "table" and config.modules[name]) or {}
  return verbatim.checked(block.verbatim, "modules." .. name .. ".verbatim")
end

--- Whether the main build carries code anywhere, which puts EVERY one of its
--- projects in the real-tree layout: a generated module directory would
--- collide with the root link of the real one (spec 7.1).
function carried.build_carries(config)
  return config.verbatim ~= nil or config.settingsVerbatim ~= nil or next(module_verbatims(config)) ~= nil
end

--- Whether an included build carries code, in its root or its settings.
function carried.included_build_carries(block)
  return block.verbatim ~= nil or block.settingsVerbatim ~= nil
end

--- The main build's carried settings code, checked, or nil.
function carried.settings_of(config)
  return verbatim.checked(config.settingsVerbatim, "settingsVerbatim")
end

local function build_carries_kotlin(config)
  if carried.is_kotlin(carried.root_of(config)) then return true end
  for name in pairs(module_verbatims(config)) do
    if carried.is_kotlin(carried.module_of(config, name)) then return true end
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
--- @param checked what `verbatim.checked` returned, nil for no carried code
function carried.script_of(name, checked)
  return SCRIPTS .. base_of(name) .. (carried.is_kotlin(checked) and KOTLIN or GROOVY)
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

--- From an included build's derived root to the real root of the instance it belongs to.
--- @param root the instance's real root from the main derived root, `context.root`
function carried.real_root_from_included(name, root)
  local _, separators = string.gsub(composite.path_of(name), "/", "")
  return string.rep("../", separators + 1) .. root .. "/"
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

--- Refuses to render a build without carried code into a derived root that a
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
          .. ' carrying code placed (listed in "' .. record .. '"), and a build without'
          .. ' "verbatim" would write through them: run "daukle clean" first', 0)
  end
end

return carried
