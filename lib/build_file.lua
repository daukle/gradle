--- Rendering the build Gradle reads.
---
--- The whole point of this file is in two lines of what it writes: the source
--- sets point back at the real tree, and every dependency is an absolute path
--- into daukle's artifact cache. So there is NO `repositories {}` block and
--- Gradle resolves nothing. Resolution is daukle/maven's, which is the end goal
--- rather than a convenience.

local build_file = {}

local configurations = daukle.require("lib/configurations")
local groovy = daukle.require("lib/groovy")
local extensions = daukle.require("lib/extensions")
local composite = daukle.require("lib/composite")
local source_sets = daukle.require("lib/source_sets")
local carried = daukle.require("lib/carried")
local declared_configurations = daukle.require("lib/declared_configurations")

--[[ The derived directory is build/daukle/gradle/, so the project root is three
     levels up. It is load bearing and fails SILENTLY when wrong: with the
     sourceSets block removed, Gradle resolves src/main/java against the project
     directory, finds nothing, compiles nothing and exits 0 on `classes`. That
     is why the tests assert on compiled output and never on this text. ]]
local ROOT = "../../.."

--- A module's projectDir sits one level deeper than the derived root per
--- component of its name, so the climb back to the project root grows with it.
--- Same silent failure as ROOT when wrong.
local function root_of(name)
  local _, separators = string.gsub(name, "/", "")
  return ROOT .. string.rep("/..", separators + 1)
end

local src_dirs = groovy.src_dirs
local file_list = groovy.file_list

local function source_set(name, java_dirs, resource_dirs, depth)
  return "  " .. name .. " {\n"
         .. "    java      { " .. src_dirs(java_dirs, depth) .. " }\n"
         .. "    resources { " .. src_dirs(resource_dirs, depth) .. " }\n"
         .. "  }"
end

--- Every `configure` block, as Groovy text. Pure, so `generate` can run it to
--- refuse a bad tree before anything is acquired.
---
--- @param depth the `file` marker's prefix, defaulting to the derived root's,
--- so a caller that only validates a tree needs to know nothing about depth
function build_file.configuration(configure, depth, label)
  return extensions.configuration(configure, depth or ROOT, label)
end

--- A module name is its directory, so its Gradle project path is the same
--- components joined by ":" instead of "/".
local function gradle_path(name)
  return ":" .. (string.gsub(name, "/", ":"))
end

--- The ids the `plugins {}` block applies: Gradle's own the manifest implies,
--- then every id an included build owns.
---
--- @implNote `application` alongside `java` when a main class is declared,
--- because the application EXTENSION is the only place a packaging plugin looks
--- for one: shadow reads Main-Class from there, so a generated build applying
--- only `java` produced a fat jar whose manifest named no entry point and which
--- nothing could run. Both are built into Gradle, so naming them here resolves
--- nothing and the no-repository property is untouched.
local function block_ids(jars, options)
  local ids = { configurations.needs_java_library(jars) and "java-library" or "java" }
  if #(options.gradle_plugins or {}) > 0 then ids[#ids + 1] = "java-gradle-plugin" end
  if options.main ~= nil then ids[#ids + 1] = "application" end
  for _, id in ipairs(options.included_plugins or {}) do ids[#ids + 1] = id end
  return ids
end

local function append_apply_lines(lines, options)
  local core_plugins = options.core_plugins or {}
  for index = 1, #core_plugins do
    lines[#lines + 1] = "apply plugin: " .. groovy.quoted(core_plugins[index])
  end
  if #core_plugins > 0 then lines[#lines + 1] = "" end

  for index = 1, #options.plugins do
    lines[#lines + 1] = "apply plugin: " .. groovy.quoted(options.plugins[index].id)
  end
  if #options.plugins > 0 then lines[#lines + 1] = "" end
end

--- Every id a project applies, which a Kotlin wrapper names in its own
--- `plugins {}` so their accessors compile (spec 7.2).
function build_file.plugin_ids(jars, options)
  local ids = block_ids(jars, options)
  for _, id in ipairs(options.core_plugins or {}) do ids[#ids + 1] = id end
  for _, plugin in ipairs(options.plugins) do ids[#ids + 1] = plugin.id end
  return ids
end

--- @param layout   { main = {java, resources}, test = {java, resources} }
--- @param jars     { compile = {path...}, test = {path...}, plugin = {path...},
---                   named = { { name, paths = {path...} } } }
--- @param options  { release, main, plugins, core_plugins, configure, requires, included_plugins,
---                   required_builds, gradle_plugins, group, version, sources_jar,
---                   source_sets, real_tree }
---                 `real_tree` = { build_directory, wrapped } for a project of a build that
---                 carries logic; `wrapped` leaves plugin application to a Kotlin wrapper
--- @param depth    the `file('...')` prefix the source roots resolve against
--- @param prefix   the project's directory under that root, nil for the root itself
local function render_project(layout, jars, options, depth, prefix)
  local requires = options.requires or {}
  local sets = options.source_sets or {}
  local real_tree = options.real_tree
  local wrapped = real_tree ~= nil and real_tree.wrapped
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
       nothing else to keep.

       A module takes its plugin classpath from the root, so only the project at
       the derived root carries this block. ]]
  if (depth == ROOT or real_tree ~= nil) and not wrapped and #jars.plugin > 0 then
    lines[#lines + 1] = "buildscript {"
    lines[#lines + 1] = "  dependencies {"
    lines[#lines + 1] = "    classpath files(\n" .. file_list(jars.plugin, "      ") .. "\n    )"
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
  end

  local gradle_plugins = options.gradle_plugins or {}
  if not wrapped then
    for _, line in ipairs(composite.plugins_block(block_ids(jars, options))) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
  end
  if options.group ~= nil then
    lines[#lines + 1] = "group = " .. groovy.quoted(options.group)
    lines[#lines + 1] = ""
  end
  if options.version ~= nil then
    lines[#lines + 1] = "version = " .. groovy.quoted(options.version)
    lines[#lines + 1] = ""
  end

  if not wrapped then append_apply_lines(lines, options) end
  if real_tree ~= nil then
    lines[#lines + 1] = "layout.buildDirectory.set(" .. real_tree.build_directory .. ")"
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "sourceSets {"
  lines[#lines + 1] = source_set("main", layout.main.java, layout.main.resources, depth)
  lines[#lines + 1] = source_set("test", layout.test.java, layout.test.resources, depth)
  for _, set in ipairs(sets) do lines[#lines + 1] = source_sets.entry(set, depth) end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  for _, line in ipairs(source_sets.configurations_block(sets)) do lines[#lines + 1] = line end
  local declared = options.declared_configurations or {}
  for _, line in ipairs(declared_configurations.configurations_lines(declared)) do lines[#lines + 1] = line end
  lines[#lines + 1] = "dependencies {"
  for index = 1, #requires do
    lines[#lines + 1] = "  implementation project("
                        .. groovy.quoted(gradle_path(requires[index])) .. ")"
  end
  for _, build_name in ipairs(options.required_builds or {}) do
    lines[#lines + 1] = "  implementation " .. groovy.quoted(composite.GROUP .. ":" .. build_name)
  end
  for index = 1, #configurations.all do
    local row = configurations.all[index]
    local paths = jars[row.key]
    if paths ~= nil and #paths > 0 then
      lines[#lines + 1] = "  " .. row.render .. " files(\n" .. file_list(paths, "    ") .. "\n  )"
    end
  end
  for _, named in ipairs(jars.named or {}) do
    if #named.paths > 0 then
      lines[#lines + 1] = "  " .. named.name .. " files(\n" .. file_list(named.paths, "    ")
                          .. "\n  )"
    end
  end
  for _, line in ipairs(source_sets.dependency_lines(sets)) do lines[#lines + 1] = line end
  for _, line in ipairs(declared_configurations.dependency_lines(declared, gradle_path)) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  for _, line in ipairs(declared_configurations.artifacts_lines(declared)) do lines[#lines + 1] = line end

  if options.release ~= nil or options.sources_jar then
    lines[#lines + 1] = "java {"
    if options.release ~= nil then
      lines[#lines + 1] = "  sourceCompatibility = JavaVersion.toVersion("
                          .. groovy.quoted(options.release) .. ")"
      lines[#lines + 1] = "  targetCompatibility = JavaVersion.toVersion("
                          .. groovy.quoted(options.release) .. ")"
    end
    if options.sources_jar then lines[#lines + 1] = "  withSourcesJar()" end
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
  for _, line in ipairs(source_sets.test_task_lines(sets)) do lines[#lines + 1] = line end
  if #gradle_plugins > 0 then
    lines[#lines + 1] = ""
    for _, line in ipairs(composite.gradle_plugin_block(gradle_plugins)) do
      lines[#lines + 1] = line
    end
  end

  local configuration = build_file.configuration(options.configure, depth)
  for index = 1, #configuration do
    --[[ One blank line before each top-level block, which is every line this
         returns at indent zero that is not a closing brace. ]]
    if configuration[index]:sub(1, 1) ~= " " and configuration[index] ~= "}" then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = configuration[index]
  end

  local real_dir = "file(" .. groovy.quoted(depth) .. ")"
  if prefix ~= nil then real_dir = "new File(" .. real_dir .. ", " .. groovy.quoted(prefix) .. ")" end
  lines[#lines + 1] = ""
  for _, line in ipairs(source_sets.conventional_roots(real_dir, sets)) do
    lines[#lines + 1] = line
  end

  --[[ Only for a discovery run, so an ordinary build file carries no task
       nobody asked for. `discover` is the MARKER the caller prints with rather
       than a flag, because a second copy of that string here and in
       lib/discovery is two things that will one day disagree. Both halves of a
       discovery write this block, so it cancels out of the difference the way
       Gradle's own tasks do. ]]
  if options.discover ~= nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "tasks.register('daukleTasks') {"
    lines[#lines + 1] = "  doLast {"
    lines[#lines + 1] = "    project.tasks.names.each { println "
                        .. groovy.quoted(options.discover) .. " + it }"
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = "}"
  end

  --[[ `daukleRun` is kept beside the `run` that `application` contributes
       rather than replaced by it: gradle:run is a published surface two
       examples exercise, and a task this plugin registers itself cannot be
       renamed or reconfigured by a third-party plugin the project applies. ]]
  if options.main ~= nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "application {"
    lines[#lines + 1] = "  mainClass = " .. groovy.quoted(options.main)
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "tasks.register('daukleRun', JavaExec) {"
    lines[#lines + 1] = "  classpath = sourceSets.main.runtimeClasspath"
    lines[#lines + 1] = "  mainClass = " .. groovy.quoted(options.main)
    lines[#lines + 1] = "}"
  end

  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

--- One module's build file, its source roots climbing back from its own depth.
function build_file.module(name, layout, jars, options)
  return render_project(layout, jars, options, root_of(name), name)
end

function build_file.render(layout, jars, options)
  return render_project(layout, jars, options, ROOT)
end

--- A project of a build that carries logic, in its real directory: the root
--- (name nil) or a module, or an included build's root by the build's name.
function build_file.real_tree_project(name, layout, jars, options)
  return render_project(layout, jars, options, carried.depth_of(name), name)
end

--- The root file of a multi-project build that carries logic: today's
--- classpath header, and the build directory every project of it moves.
function build_file.real_tree_header(plugin_jars)
  return build_file.buildscript(plugin_jars)
         .. "layout.buildDirectory.set(" .. carried.build_directory_of(nil) .. ")\n"
end

--- An included build's file, its source roots climbing back from its directory
--- inside the derived one.
function build_file.included(name, layout, jars, options)
  return render_project(layout, jars, options, root_of(composite.path_of(name)), name)
end

--- The root build file of a multi-project build, which carries the buildscript
--- classpath and nothing else.
---
--- @implNote a subproject's `apply plugin:` resolves against the ROOT's
--- buildscript classpath and there is no other place to put it: measured both
--- ways, and without this file Gradle answers "Plugin with id ... not found".
--- It holds no sources because 58 of the 60 multi-project roots in this tree
--- have none.
--- @implNote an empty classpath still renders the header, so the caller has a
--- file to write in every case. A root project whose build file declares
--- nothing contributes no task to an unqualified name and nothing to a
--- discovery, which a single-project file left behind by an earlier build does.
function build_file.buildscript(plugin_jars)
  local lines = { "// Generated by daukle/gradle. Do not edit.", "" }
  if #plugin_jars > 0 then
    lines[#lines + 1] = "buildscript {"
    lines[#lines + 1] = "  dependencies {"
    lines[#lines + 1] = "    classpath files(\n" .. file_list(plugin_jars, "      ") .. "\n    )"
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

--- An implicit parent project's file: the header and nothing else, so a build
--- file an earlier run left in its directory is overwritten rather than read.
function build_file.empty_project()
  return build_file.buildscript({})
end

build_file.gradle_path = gradle_path
build_file.file_list = file_list

return build_file
