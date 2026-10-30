--- The module graph this toolchain renders, read from what core hands a
--- callback rather than from the manifest text.

local modules = {}

local configurations = daukle.require("lib/configurations")

local function slash_form(name)
  local trimmed = string.gsub(name, "^:", "")
  return (string.gsub(trimmed, ":", "/"))
end

local function component_problem(component)
  if component == "" then return "holds an empty path component" end
  if component == "." or component == ".." then
    return 'holds a "' .. component .. '" path component'
  end
  return nil
end

--- @implNote a backslash is refused because the renderer would turn it into a
--- separator and smuggle a nesting past this guard. "." is refused because it
--- renders a path that writes a build file over its parent's, and ".." because
--- core refuses it only at write time, in words that name a path rather than
--- the module the name came from.
function modules.problem_of(name)
  if name == "" then return "is empty" end
  if string.find(name, "%c") ~= nil then return "holds a control character" end
  if string.find(name, "\\", 1, true) ~= nil then return 'holds a "\\"' end
  if string.find(name, ":", 1, true) ~= nil then
    return 'holds a ":", which is Gradle\'s spelling: write "' .. slash_form(name) .. '"'
  end
  for component in string.gmatch(name .. "/", "([^/]*)/") do
    local problem = component_problem(component)
    if problem ~= nil then return problem end
  end
  return nil
end

local function name_problem(name)
  local problem = modules.problem_of(name)
  if problem == nil then return nil end
  return 'the module "' .. name .. '" ' .. problem .. '. A module name is its directory, with'
         .. ' "/" between components'
end

local function unknown_requires_problem(declared)
  local known = {}
  for index = 1, #declared do known[declared[index].name] = true end
  for index = 1, #declared do
    local entry = declared[index]
    for edge = 1, #entry.requires do
      if known[entry.requires[edge]] == nil then
        return 'the module "' .. entry.name .. '" requires "' .. entry.requires[edge]
               .. '", which this project does not declare'
      end
    end
  end
  return nil
end

--- @implNote separate from the two-module cycle below because a self-require
--- is one module and not two: that check would answer with the same name
--- twice, which reads as a defect in the refusal rather than in the manifest.
local function self_require_problem(declared)
  for index = 1, #declared do
    local entry = declared[index]
    for edge = 1, #entry.requires do
      if entry.requires[edge] == entry.name then
        return 'the module "' .. entry.name .. '" cannot require itself'
      end
    end
  end
  return nil
end

--- @implNote catches two modules requiring each other, the shape a user
--- writes, and nothing longer: a longer cycle is left to Gradle to name.
--- Refused here because this check needs no Gradle and so runs on every host.
local function two_module_cycle_problem(declared)
  local requires_of = {}
  for index = 1, #declared do requires_of[declared[index].name] = declared[index].requires end
  for index = 1, #declared do
    local name = declared[index].name
    for edge = 1, #declared[index].requires do
      local other = declared[index].requires[edge]
      for back = 1, #requires_of[other] do
        if requires_of[other][back] == name then
          return 'the modules "' .. name .. '" and "' .. other .. '" cannot depend on each other'
        end
      end
    end
  end
  return nil
end

--- Why `declared` would refuse the module list a context carries, or nil.
--- @implNote the migrator asks for the reason, because it reports a refusal
--- as a blocker and the sandbox has no pcall.
function modules.declared_problem(context)
  local declared = context.modules or {}
  for index = 1, #declared do
    local problem = name_problem(declared[index].name)
    if problem ~= nil then return problem end
  end
  return unknown_requires_problem(declared) or self_require_problem(declared)
         or two_module_cycle_problem(declared)
end

--- @implNote core publishes `{ name, requires }` per module in both the
--- generate and the task context, and `requires` is always a list. A project
--- with no `[modules]` yields an empty list, which is what keeps the
--- single-project rendering untouched.
--- @implNote nothing here type-checks `context.modules` or an entry's
--- `requires`, because neither can arrive malformed and a guard would be
--- unreachable: core's `push_modules` builds both tables itself, and
--- `fr_json_object` refuses a `modules` that is not an object before any
--- callback runs.
--- @param context a generate or task context
--- @return { { name = string, requires = { string } } } in manifest order
function modules.declared(context)
  local problem = modules.declared_problem(context)
  if problem ~= nil then error(problem, 0) end
  local declared = context.modules or {}
  local out = {}
  for index = 1, #declared do
    out[#out + 1] = { name = declared[index].name, requires = declared[index].requires }
  end
  return out
end

--- Every ancestor of a declared module that is not itself declared, in the
--- order first met. Gradle makes each one an implicit project and reads any
--- build file already in its directory.
--- @return { string }
function modules.undeclared_parents(declared)
  local known = {}
  for index = 1, #declared do known[declared[index].name] = true end
  local parents = {}
  for index = 1, #declared do
    local name = declared[index].name
    local cut = string.find(name, "/", 1, true)
    while cut ~= nil do
      local parent = string.sub(name, 1, cut - 1)
      if known[parent] == nil then
        known[parent] = true
        parents[#parents + 1] = parent
      end
      cut = string.find(name, "/", cut + 1, true)
    end
  end
  return parents
end

--- Why `refuse_two_mains` would refuse, or nil.
--- @param checked records each with `name` and `main`, in manifest order
function modules.two_mains_problem(checked)
  local found = nil
  for index = 1, #checked do
    if checked[index].main ~= nil then
      if found ~= nil then
        return 'the modules "' .. found .. '" and "' .. checked[index].name .. '" both declare'
               .. ' "main", and "gradle:run" cannot name which one it means'
      end
      found = checked[index].name
    end
  end
  return nil
end

--- @implNote a daukle task takes no arguments, so `gradle:run` cannot name a
--- module. Running every runnable module instead is nobody's intent.
--- @param checked the records `checked_modules` builds, each with `name` and `main`
function modules.refuse_two_mains(checked)
  local problem = modules.two_mains_problem(checked)
  if problem ~= nil then error(problem, 0) end
end

local DEFAULT_SUFFIX = {
  sourceRoot = "src/main/java",
  resourceRoot = "src/main/resources",
  testSourceRoot = "src/test/java",
  testResourceRoot = "src/test/resources",
}

--- @param label where the key really lives, when that is not the key itself: a
--- module's fault names "modules.<name>.<key>" so the refusal names something
--- the manifest actually holds
function modules.string_key(block, key, fallback, label)
  local value = block[key]
  if value == nil then return fallback end
  if type(value) ~= "string" then
    error('"' .. (label or key) .. '" must be a string, not a ' .. type(value), 0)
  end
  return value
end

function modules.boolean_key(block, key, fallback, label)
  local value = block[key]
  if value == nil then return fallback end
  if type(value) ~= "boolean" then
    error('"' .. (label or key) .. '" must be true or false, not a ' .. type(value), 0)
  end
  return value
end

--- The project-wide keys that are neither a path nor a dependency, read in one
--- place so `generate` refuses exactly what the writer would.
function modules.project_options(config)
  return { release = modules.string_key(config, "release", nil),
           main = modules.string_key(config, "main", nil),
           sources_jar = modules.boolean_key(config, "sourcesJar", false) }
end

local BUILD_OUTPUT = "buildOutput"
local ROOT_SHAPE = 'a path or a { buildOutput = "<path>" } marker'

local function climbs_out(path)
  if string.match(path, "^[/\\]") or string.match(path, "^%a:") then return true end
  for part in string.gmatch(path, "[^/\\]+") do
    if part == ".." then return true end
  end
  return false
end

local function table_size(value)
  local keys = 0
  for _ in pairs(value) do keys = keys + 1 end
  return keys
end

local function checked_build_output(entry, name)
  if entry[BUILD_OUTPUT] == nil or table_size(entry) ~= 1 then
    error('"' .. name .. '" must be ' .. ROOT_SHAPE .. ', not a table of other keys', 0)
  end
  local path = entry[BUILD_OUTPUT]
  if type(path) ~= "string" then
    error('"' .. name .. '.' .. BUILD_OUTPUT .. '" must be a string, not a ' .. type(path), 0)
  end
  if climbs_out(path) then
    error('"' .. name .. '.' .. BUILD_OUTPUT .. '" must stay inside the build directory, not "'
          .. path .. '"', 0)
  end
  return entry
end

local function checked_root(entry, name)
  if type(entry) == "string" then return entry end
  if type(entry) == "table" then return checked_build_output(entry, name) end
  error('"' .. name .. '" must be ' .. ROOT_SHAPE .. ', not a ' .. type(entry), 0)
end

--- One root or a list of them, always returned as a list: Gradle's `srcDirs`
--- takes several roots, and an empty list is its way of declaring none. A root
--- is a path relative to the project, or a `buildOutput` marker relative to its
--- build directory, wherever daukle put that (D-191).
function modules.root_list_key(block, key, fallback, label)
  local value = block[key]
  local name = label or key
  if value == nil then return { fallback } end
  if type(value) ~= "table" or value[BUILD_OUTPUT] ~= nil then return { checked_root(value, name) } end
  if table_size(value) ~= #value then
    error('"' .. name .. '" must be ' .. ROOT_SHAPE .. ' or a list of them, not a table of keys', 0)
  end
  for index, entry in ipairs(value) do checked_root(entry, name .. '[' .. index .. ']') end
  return value
end

--- The source layout of one module, or of the project itself when `name` is nil.
---
--- @implNote a module's roots default to its own name, which is the shape 117
--- of this tree's 185 subproject build files rely on: they declare nothing and
--- take the convention. One function for both so the four defaults live in one
--- table: a second copy drifts the first time a fifth root is added.
function modules.layout_of(name, block, kind)
  block = block or {}
  kind = kind or "modules"
  local prefix = name ~= nil and (name .. "/") or ""
  local scope = name ~= nil and (kind .. "." .. name .. ".") or ""
  local function dirs_for(key)
    return modules.root_list_key(block, key, prefix .. DEFAULT_SUFFIX[key], scope .. key)
  end
  return {
    main = { java = dirs_for("sourceRoot"), resources = dirs_for("resourceRoot") },
    test = { java = dirs_for("testSourceRoot"), resources = dirs_for("testResourceRoot") },
  }
end

local MODULE_KEYS = {
  sourceRoot = true, resourceRoot = true, testSourceRoot = true, testResourceRoot = true,
  main = true, requiresBuilds = true, sourceSets = true, configurations = true, verbatim = true,
  declaredConfigurations = true, plugins = true, configure = true, release = true, sourcesJar = true,
}

--- Module keys that stay legal beside declared modules: one pinned closure
--- serves every module, and a module's own entry replaces it by name; a
--- project-wide `verbatim` is the root project's own; the other four are what
--- Gradle's `subprojects {}` would hold, and a module's own value composes with
--- them (D-168).
local PROJECT_WIDE_KEYS = { configurations = true, verbatim = true, plugins = true, configure = true,
                            release = true, sourcesJar = true }

for index = 1, #configurations.all do
  MODULE_KEYS[configurations.all[index].key] = true
end

--- The keys a `[toolchains.gradle.modules.<name>]` block takes.
modules.MODULE_KEYS = MODULE_KEYS

--- @implNote core reads only `requires` in its `[modules.<n>]` and hands every
--- other key on unread, so a module key written there does nothing and only
--- this plugin can see it (D-128). A daukle.lua project has no parsed manifest
--- here and goes unchecked.
function modules.refuse_toolchain_keys_in_core_modules(manifest)
  local blocks = manifest ~= nil and manifest.modules or nil
  if type(blocks) ~= "table" then return end
  for name, block in pairs(blocks) do
    if type(block) == "table" then
      for key in pairs(block) do
        if MODULE_KEYS[key] then
          error('"modules.' .. name .. '.' .. key .. '" is in core\'s "[modules.' .. name .. ']",'
                .. ' which this toolchain never reads: write it under'
                .. ' "[toolchains.gradle.modules.' .. name .. ']"', 0)
        end
      end
    end
  end
end

--- Keys a module block may not hold although the top level may, each with why.
local PROJECT_ONLY_REASONS = {
  pluginClasspath = '"pluginClasspath" is project-wide: the root build file holds it and every'
                    .. " module's classloader inherits it",
}

--- @implNote refused rather than ignored: before D-168 a module's "plugins" was read by nothing
--- and rendered nothing, at exit 0.
local function refuse_an_unknown_module_key(name, block)
  if type(block) ~= "table" then return end
  for key in pairs(block) do
    if not MODULE_KEYS[key] then
      local message = '"modules.' .. name .. '.' .. tostring(key) .. '" is not a key a module takes'
      local reason = PROJECT_ONLY_REASONS[key]
      error(message .. (reason ~= nil and (": " .. reason) or ""), 0)
    end
  end
end

--- The toolchain's own per-module blocks, checked against the graph.
function modules.blocks_of(config, declared)
  local blocks = config.modules
  if blocks == nil then return {} end
  if type(blocks) ~= "table" then
    error('"modules" must be a table of per-module blocks, not a ' .. type(blocks), 0)
  end
  local known = {}
  for index = 1, #declared do known[declared[index].name] = true end
  for name, block in pairs(blocks) do
    if known[name] == nil then
      error('"modules.' .. tostring(name) .. '" names no module this project declares: a'
            .. ' module is declared in "[modules]" and configured here', 0)
    end
    refuse_an_unknown_module_key(name, block)
  end
  return blocks
end

--- @implNote a module key left at the top level would apply to every module at
--- once, silently. Same rule and same reason as daukle/cmake's "targets".
function modules.refuse_a_module_key_project_wide(config, declared)
  if #declared == 0 then return end
  for key in pairs(MODULE_KEYS) do
    if config[key] ~= nil and not PROJECT_WIDE_KEYS[key] then
      error('"' .. key .. '" belongs to a module and this project declares modules, so it has'
            .. ' to live in "[toolchains.gradle.modules.<name>]": a project-wide "' .. key
            .. '" would apply to every module at once', 0)
    end
  end
end

return modules
