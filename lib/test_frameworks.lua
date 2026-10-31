--- The framework a project's `test` task runs, `testFramework`: the JUnit
--- Platform by default, or JUnit 4 or TestNG.
local test_frameworks = {}

local CALLS = { junitPlatform = "useJUnitPlatform()", junit = "useJUnit()", testng = "useTestNG()" }

test_frameworks.DEFAULT = "junitPlatform"

--- The dump's options type of each framework (`lib/model_dump.lua`, the `test` reader).
local BY_OPTIONS_TYPE = {
  ["org.gradle.api.tasks.testing.junitplatform.JUnitPlatformOptions"] = "junitPlatform",
  ["org.gradle.api.tasks.testing.junit.JUnitOptions"] = "junit",
  ["org.gradle.api.tasks.testing.testng.TestNGOptions"] = "testng",
}

--- `block.testFramework`, checked, or `fallback` when it is unset.
function test_frameworks.read(block, fallback, label)
  local value = block.testFramework
  if value == nil then return fallback end
  if CALLS[value] == nil then
    error('"' .. label .. '" must be "junitPlatform", "junit" or "testng", not ' .. tostring(value), 0)
  end
  return value
end

--- The `test {}` call that selects `framework`.
function test_frameworks.call(framework)
  return CALLS[framework or test_frameworks.DEFAULT]
end

--- The key a dumped options type translates to, or nil for one this plugin does not know.
function test_frameworks.of_options_type(name)
  return BY_OPTIONS_TYPE[name]
end

return test_frameworks
