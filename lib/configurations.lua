--- The dependency configurations this toolchain renders, in the order they are
--- written into the build file.
---
--- One list so that adding a configuration is one row rather than an edit in
--- the reader, the renderer and the module key set, which is where this plugin
--- has shipped a key that half the projects got.
---
--- @implNote `classpath` and `testClasspath` keep those names because they are
--- released and a project pinning 1.5.0 must keep working. Every other key is
--- named after the Gradle configuration it maps to, so there is one spelling to
--- learn and no second name for one bucket.
--- @implNote `testRuntime` marks the configurations that reach the TEST RUNTIME
--- classpath, which is what the JUnit launcher check reads. `compileOnly` and
--- `testCompileOnly` are deliberately absent from it: a launcher declared there
--- is not on the test runtime classpath, so the refusal must still fire.

local configurations = {}

configurations.all = {
  { key = "classpath",               render = "implementation",           testRuntime = true },
  { key = "testClasspath",           render = "testImplementation",       testRuntime = true },
  { key = "compileOnly",             render = "compileOnly" },
  { key = "runtimeOnly",             render = "runtimeOnly",              testRuntime = true },
  { key = "testCompileOnly",         render = "testCompileOnly" },
  { key = "testRuntimeOnly",         render = "testRuntimeOnly",          testRuntime = true },
  { key = "annotationProcessor",     render = "annotationProcessor" },
  { key = "testAnnotationProcessor", render = "testAnnotationProcessor" },
  { key = "api",                     render = "api",            testRuntime = true, library = true },
  { key = "compileOnlyApi",          render = "compileOnlyApi",                     library = true },
}

--- Whether any configuration only `java-library` provides carries an entry.
---
--- @implNote the base plugin is switched rather than always `java-library`,
--- because that plugin splits compileClasspath so a consumer stops seeing a
--- dependency's `implementation` entries. Applying it to every project would
--- change what compiles for every project already pinning this plugin, to
--- serve a key they do not use.
function configurations.needs_java_library(jars)
  for index = 1, #configurations.all do
    local row = configurations.all[index]
    local paths = jars[row.key]
    if row.library and paths ~= nil and #paths > 0 then return true end
  end
  return false
end

--- The entries a test run can load, which is every configuration on the test
--- runtime classpath concatenated in declaration order.
function configurations.test_reachable(entries_of)
  local reachable = {}
  for index = 1, #configurations.all do
    local row = configurations.all[index]
    if row.testRuntime then
      local entries = entries_of(row.key)
      for at = 1, #entries do reachable[#reachable + 1] = entries[at] end
    end
  end
  return reachable
end

--- Why `checked_entries` would refuse this list, or nil.
function configurations.entries_problem(entries, key)
  if entries == nil then return nil end
  if type(entries) ~= "table" then
    return '"' .. key .. '" must be a list of pinned entries, not a ' .. type(entries)
  end
  for index = 1, #entries do
    local entry = entries[index]
    if type(entry) ~= "table" or type(entry.url) ~= "string"
       or type(entry.sha256) ~= "string" then
      return '"' .. key .. '[' .. index .. ']" needs a url and a sha256: every dependency this'
             .. ' toolchain gives Gradle is pinned before Gradle sees it'
    end
  end
  return nil
end

function configurations.checked_entries(entries, key)
  local problem = configurations.entries_problem(entries, key)
  if problem ~= nil then error(problem, 0) end
  return entries or {}
end

--- Every pinned entry a configuration holds, keyed by its manifest name.
---
--- @implNote read through one list rather than key by key, so a configuration
--- added above reaches the reader, the renderer, the launcher check and the
--- module key set at once.
function configurations.entries_of(block, scope)
  local entries = {}
  for index = 1, #configurations.all do
    local key = configurations.all[index].key
    entries[key] = configurations.checked_entries(block[key], scope .. key)
  end
  return entries
end

local function modelled_key_for(render)
  for index = 1, #configurations.all do
    local row = configurations.all[index]
    if row.render == render then return row.key end
  end
  return nil
end

local function named_problem(name, scope)
  local label = scope .. "configurations." .. tostring(name)
  if type(name) ~= "string" or string.match(name, "^[%a_][%w_]*$") == nil then
    return '"' .. label .. '" is not a configuration name: it is written into the build as a'
           .. " Gradle identifier, so letters, digits and underscores only"
  end
  local modelled = modelled_key_for(name)
  if modelled ~= nil then
    return '"' .. label .. '" is a configuration this toolchain already models: pin it under "'
           .. scope .. modelled .. '"'
  end
  return nil
end

--- Why `named` would refuse the `configurations` table of a block, or nil.
function configurations.named_problem_of(block, scope)
  local named = block.configurations
  if named == nil then return nil end
  local label = scope .. "configurations"
  if type(named) ~= "table" then
    return '"' .. label .. '" must be a table of pinned lists keyed by configuration name, not a '
           .. type(named)
  end
  for name, entries in pairs(named) do
    local problem = named_problem(name, scope)
                    or configurations.entries_problem(entries, scope .. "configurations." .. name)
    if problem ~= nil then return problem end
  end
  return nil
end

--- The configurations a block pins by a name of its own, which is every name
--- the ten above do not already cover.
---
--- @implNote read by name and not by a list in this file, so a plugin that adds
--- a configuration needs no edit here: Gradle is the one that knows whether the
--- name exists, and says so itself when it does not.
--- @param scope the manifest path of `block`, so a refusal names a key that exists
--- @return { { name = string, entries = table } } sorted by name
function configurations.named(block, scope)
  scope = scope or ""
  local problem = configurations.named_problem_of(block, scope)
  if problem ~= nil then error(problem, 0) end
  local named = {}
  for name, entries in pairs(block.configurations or {}) do
    named[#named + 1] = { name = name, entries = entries }
  end
  table.sort(named, function(left, right) return left.name < right.name end)
  return named
end

--- `wide` with every name `own` pins replaced by `own`'s entries.
function configurations.overridden(wide, own)
  local taken = {}
  for index = 1, #own do taken[own[index].name] = true end
  local merged = {}
  for index = 1, #wide do
    if not taken[wide[index].name] then merged[#merged + 1] = wide[index] end
  end
  for index = 1, #own do merged[#merged + 1] = own[index] end
  table.sort(merged, function(left, right) return left.name < right.name end)
  return merged
end

return configurations
