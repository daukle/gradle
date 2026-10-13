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

return configurations
