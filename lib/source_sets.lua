--- Custom source sets and test sets, `[toolchains.gradle.sourceSets.<name>]`.
---
--- @implNote rendered as a plain source set plus, for a test set, a registered
--- Test task, never through `testing { suites {} }`: every suite but the
--- built-in one adds an external JUnit dependency on 7.6.4, 8.13 and 9.6.0, and
--- this build declares no repository (2026-10-14 source sets design, section 1).

local module_graph = daukle.require("lib/modules")
local configurations = daukle.require("lib/configurations")
local groovy = daukle.require("lib/groovy")
local junit = daukle.require("lib/junit")
local discovery = daukle.require("lib/discovery")

local source_sets = {}

source_sets.CONFIGURATIONS = {
  { key = "classpath",           suffix = "Implementation",      testRuntime = true },
  { key = "compileOnly",         suffix = "CompileOnly" },
  { key = "runtimeOnly",         suffix = "RuntimeOnly",         testRuntime = true },
  { key = "annotationProcessor", suffix = "AnnotationProcessor" },
}

local KEYS = { test = true, sourceRoot = true, resourceRoot = true }
for _, row in ipairs(source_sets.CONFIGURATIONS) do KEYS[row.key] = true end

local RESERVED = { main = true, test = true }

--- @implNote main's configurations a test set inherits through
--- `<name>Implementation.extendsFrom implementation` and
--- `<name>RuntimeOnly.extendsFrom runtimeOnly`; `api` arrives because
--- `java-library` makes `implementation` extend it.
local INHERITED_FROM_MAIN = { "classpath", "runtimeOnly", "api" }

--- @implNote the union of what `java` and `application` register on 7.6.4,
--- 8.13 and 9.6.0, measured 2026-10-14 from `project.tasks.names`, plus this
--- plugin's own. A test set registers a Test task under its own name, and
--- Gradle answers "Cannot add task 'jar' as a task with that name already
--- exists" for one that is taken.
local TAKEN_TASK_NAMES = {}
for name in ([[
  artifactTransforms assemble assembleDist build buildDependents buildEnvironment buildNeeded
  check classes clean compileJava compileTestJava components daukleRun daukleTasks dependencies
  dependencyInsight dependentComponents distTar distZip help init installDist jar javaToolchains
  javadoc model outgoingVariants prepareKotlinBuildScriptModel processResources
  processTestResources projects properties resolvableConfigurations run sourcesJar startScripts
  tasks test testClasses updateDaemonJvm wrapper
]]):gmatch("%S+") do
  TAKEN_TASK_NAMES[name] = true
end

--- @implNote 64 keeps the longest kebab spelling of a name (96 characters)
--- inside the 128 bytes core allows a task's `daukle.task/<name>` capability.
local NAME_LIMIT = 64

local function is_usable_name(name)
  return type(name) == "string" and #name <= NAME_LIMIT and name:match("^%l[%a%d]*$") ~= nil
end

local function refuse_a_bad_name(name, label)
  if not is_usable_name(name) then
    error('"' .. label .. '.' .. tostring(name) .. '" is not a source set name: start with a'
          .. ' lowercase letter and use only letters and digits, at most ' .. NAME_LIMIT
          .. ' of them, as in "integrationTest", because the name becomes a configuration'
          .. ' prefix and a task name', 0)
  end
  if RESERVED[name] then
    error('"' .. label .. '.' .. name .. '" is Gradle\'s own source set: name yours'
          .. ' something else', 0)
  end
end

local function sorted_names(blocks, label)
  local names = {}
  for name in pairs(blocks) do
    refuse_a_bad_name(name, label)
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function refuse_a_missing_launcher(set, main_entries)
  local reachable = {}
  local function add(entries)
    for _, entry in ipairs(entries) do reachable[#reachable + 1] = entry end
  end
  for _, key in ipairs(INHERITED_FROM_MAIN) do add(main_entries[key]) end
  for _, row in ipairs(source_sets.CONFIGURATIONS) do
    if row.testRuntime then add(set.entries[row.key]) end
  end
  junit.refuse_a_missing_launcher(reachable)
end

local function read_one(name, block, where, prefix, main_entries)
  if type(block) ~= "table" then
    error('"' .. where .. '" must be a block, not a ' .. type(block), 0)
  end
  for key in pairs(block) do
    if KEYS[key] == nil then
      error('"' .. where .. '.' .. tostring(key) .. '" is not a key a source set takes', 0)
    end
  end
  local set = {
    name = name,
    label = where,
    test = module_graph.boolean_key(block, "test", false, where .. ".test"),
    java = module_graph.root_list_key(block, "sourceRoot", prefix .. "src/" .. name .. "/java",
                                      where .. ".sourceRoot"),
    resources = module_graph.root_list_key(block, "resourceRoot",
                                           prefix .. "src/" .. name .. "/resources",
                                           where .. ".resourceRoot"),
    entries = {},
  }
  for _, row in ipairs(source_sets.CONFIGURATIONS) do
    set.entries[row.key] = configurations.checked_entries(block[row.key], where .. "." .. row.key)
  end
  if set.test then
    if TAKEN_TASK_NAMES[name] then
      error('"' .. where .. '" is a test set, and Gradle already has a task named "' .. name
            .. '" for its Test task to collide with', 0)
    end
    refuse_a_missing_launcher(set, main_entries)
  end
  return set
end

--- Every set a project or one module declares, checked, sorted by name.
--- @param owner the toolchain config, or one module's block
--- @param module_name nil for the project itself
function source_sets.read(owner, module_name)
  local scope = module_name ~= nil and ("modules." .. module_name .. ".") or ""
  local label = scope .. "sourceSets"
  local blocks = owner.sourceSets
  if blocks == nil then return {} end
  if type(blocks) ~= "table" then
    error('"' .. label .. '" must be a table of source set blocks keyed by name, not a '
          .. type(blocks), 0)
  end
  if #blocks > 0 then
    error('"' .. label .. '" must be keyed by name, as [toolchains.gradle.sourceSets.<name>],'
          .. ' not a list', 0)
  end
  local prefix = module_name ~= nil and (module_name .. "/") or ""
  local main_entries = configurations.entries_of(owner, scope)
  local sets = {}
  for index, name in ipairs(sorted_names(blocks, label)) do
    sets[index] = read_one(name, blocks[name], label .. "." .. name, prefix, main_entries)
  end
  return sets
end

--- Refuses a test set whose `gradle:<kebab>` is already a task of this
--- toolchain's: a duplicate daukle task name is fatal on every command.
--- @param modules the records `checked_modules` returns, empty without modules
function source_sets.refuse_task_collisions(config, modules)
  local owners = { #modules == 0 and source_sets.read(config, nil) or {} }
  for _, module in ipairs(modules) do owners[#owners + 1] = module.source_sets end
  local mapped, test_sets = {}, {}
  for _, entry in ipairs(discovery.mapped(config.tasks)) do mapped[entry.daukle] = entry.gradle end
  for _, sets in ipairs(owners) do
    for _, set in ipairs(sets) do
      local task = discovery.task_name(set.name)
      local other = test_sets[task]
      if set.test and other ~= nil and other.name ~= set.name then
        error('"' .. other.label .. '" and "' .. set.label .. '" both run as'
              .. ' "gradle:' .. task .. '", and a duplicate task name is fatal on every'
              .. ' command in the project', 0)
      end
      if set.test then test_sets[task] = set end
      if set.test and discovery.STATIC[task] then
        error('"' .. set.label .. '" runs as "gradle:' .. task .. '", which this'
              .. ' toolchain declares itself', 0)
      end
      if set.test and mapped[task] ~= nil then
        error('"' .. set.label .. '" runs as "gradle:' .. task .. '", which "tasks"'
              .. ' also maps "' .. mapped[task] .. '" to', 0)
      end
    end
  end
end

--- Every test set name the manifest declares, project-wide and per module.
---
--- @implNote lenient on purpose: it runs at chunk time, where a raise fails
--- every command including the `sync` that would refuse the block by name.
function source_sets.declared_test_names(config)
  local names, seen = {}, {}
  local function collect(blocks)
    if type(blocks) ~= "table" then return end
    for name, block in pairs(blocks) do
      if is_usable_name(name) and not RESERVED[name] and type(block) == "table"
         and block.test == true
         and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  if type(config) ~= "table" then return names end
  collect(config.sourceSets)
  if type(config.modules) == "table" then
    for _, block in pairs(config.modules) do
      if type(block) == "table" then collect(block.sourceSets) end
    end
  end
  table.sort(names)
  return names
end

--- One set's entry inside `sourceSets {}`. A test set sees main's classes the
--- way Gradle's own `test` does; a plain set sees nothing.
---
--- @implNote the name is always a quoted string, never a bare identifier: a
--- bare `native {` is a Groovy parse error, and a bare `all {` calls the
--- container's own all(Closure) and re-points main instead of creating a set.
function source_sets.entry(set, depth)
  local lines = {
    "  create(" .. groovy.quoted(set.name) .. ") {",
    "    java      { " .. groovy.src_dirs(set.java, depth) .. " }",
    "    resources { " .. groovy.src_dirs(set.resources, depth) .. " }",
  }
  if set.test then
    lines[#lines + 1] = "    compileClasspath += sourceSets.main.output"
    lines[#lines + 1] = "    runtimeClasspath += sourceSets.main.output"
  end
  lines[#lines + 1] = "  }"
  return table.concat(lines, "\n")
end

--- @implNote follows `sourceSets {}`, which creates the configurations it
--- names, and precedes `dependencies {}`: probe G's order, the only one
--- measured (2026-10-14 source sets design, section 4).
function source_sets.configurations_block(sets)
  local lines = {}
  for _, set in ipairs(sets) do
    if set.test then
      lines[#lines + 1] = "  " .. set.name .. "Implementation.extendsFrom implementation"
      lines[#lines + 1] = "  " .. set.name .. "RuntimeOnly.extendsFrom runtimeOnly"
    end
  end
  if #lines == 0 then return {} end
  table.insert(lines, 1, "configurations {")
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  return lines
end

function source_sets.dependency_lines(sets)
  local lines = {}
  for _, set in ipairs(sets) do
    for _, row in ipairs(source_sets.CONFIGURATIONS) do
      local paths = set.paths[row.key]
      if #paths > 0 then
        lines[#lines + 1] = "  " .. set.name .. row.suffix .. " files(\n"
                            .. groovy.file_list(paths, "    ") .. "\n  )"
      end
    end
  end
  return lines
end

function source_sets.test_task_lines(sets)
  local lines = {}
  for _, set in ipairs(sets) do
    if set.test then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "tasks.register(" .. groovy.quoted(set.name) .. ", Test) {"
      local reference = "sourceSets[" .. groovy.quoted(set.name) .. "]"
      lines[#lines + 1] = "  testClassesDirs = " .. reference .. ".output.classesDirs"
      lines[#lines + 1] = "  classpath = " .. reference .. ".runtimeClasspath"
      lines[#lines + 1] = "  useJUnitPlatform()"
      lines[#lines + 1] = "}"
    end
  end
  return lines
end

--- Every source directory a core plugin gave a set by convention, added again
--- at the same path under the real tree: `groovy`'s `src/main/groovy`,
--- `antlr`'s `src/main/antlr`, a `testFixtures` set's `java`. Names no plugin.
---
--- @param real_dir the real directory this project's derived one stands for,
--- as a Groovy expression
--- @implNote skips the java and resources of the sets this file lays out
--- itself, so a manifest that moved `sourceRoot` gets no `src/main/java`
--- beside it; and skips the build directory, where generated sources live.
--- Adds rather than replaces, for the reason `groovy.src_dirs` gives (D-178).
function source_sets.conventional_roots(real_dir, sets)
  local laid_out = { "'main'", "'test'" }
  for _, set in ipairs(sets) do laid_out[#laid_out + 1] = groovy.quoted(set.name) end
  return {
    "def daukleRealDir = " .. real_dir,
    "def daukleIsConvention = { File dir ->",
    "  dir.toPath().startsWith(projectDir.toPath()) &&",
    "    !dir.toPath().startsWith(layout.buildDirectory.get().asFile.toPath())",
    "}",
    "sourceSets.each { set ->",
    "  def directorySets = set.extensions.extensionsSchema.elements",
    "    .collect { set.extensions.getByName(it.name) }",
    "    .findAll { it instanceof SourceDirectorySet }",
    "  if (!(set.name in [" .. table.concat(laid_out, ", ") .. "])) {",
    "    directorySets += [set.java, set.resources]",
    "  }",
    "  directorySets.each { directories ->",
    "    directories.srcDirs.findAll(daukleIsConvention).each { dir ->",
    "      directories.srcDir(new File(daukleRealDir, projectDir.toPath().relativize(dir.toPath()).toString()))",
    "    }",
    "  }",
    "}",
  }
end

return source_sets
