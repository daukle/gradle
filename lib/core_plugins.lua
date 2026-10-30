--- Which core Gradle plugins a migration says as a `plugins` id, and which
--- the generated build has without one (spec D-173).
local core_plugins = {}

local CORE_PREFIX = "org.gradle."

--- The core plugins the keys imply beyond what the generated build applies:
--- `java-library` renders only when an api key is set, `application` only
--- with a main class, and `distribution` is what `application` applies itself.
core_plugins.IMPLIED = {
  ["org.gradle.java"] = true,
  ["org.gradle.java-library"] = true,
  ["org.gradle.application"] = true,
  ["org.gradle.distribution"] = true,
}

--- @implNote measured in the generated build of every brazier project on
--- 9.3.1: Gradle applies the first four to each project, and `java` applies
--- the rest itself, so naming them would only repeat what the keys give.
local APPLIED_WITHOUT_AN_ID = {
  ["org.gradle.help-tasks"] = true,
  ["org.gradle.build-init"] = true,
  ["org.gradle.software-reporting-tasks"] = true,
  ["org.gradle.wrapper"] = true,
  ["org.gradle.lifecycle-base"] = true,
  ["org.gradle.base"] = true,
  ["org.gradle.jvm-ecosystem"] = true,
  ["org.gradle.reporting-base"] = true,
  ["org.gradle.jvm-toolchains"] = true,
  ["org.gradle.java-base"] = true,
  ["org.gradle.test-suite-base"] = true,
  ["org.gradle.jvm-test-suite"] = true,
}

--- Publishing is a STOP point (D-172) and signing is D-48's, so both keep
--- blocking whatever the build sets.
local KEPT_BLOCKED = {
  ["org.gradle.publishing"] = true,
  ["org.gradle.maven-publish"] = true,
  ["org.gradle.ivy-publish"] = true,
  ["org.gradle.signing"] = true,
}

--- @implNote a `.kts` build's own script plugins report as core plugins and
--- are the DSL's, not the build's (spec D-165 section 5).
core_plugins.KOTLIN_SCRIPT = {
  ["org.gradle.kotlin.dsl.provider.plugins.KotlinScriptBasePlugin"] = true,
  ["org.gradle.kotlin.dsl.provider.plugins.KotlinScriptRootPlugin"] = true,
}

local function core_id(plugin)
  for _, id in ipairs(plugin.ids or {}) do
    if string.sub(id, 1, #CORE_PREFIX) == CORE_PREFIX then return id end
  end
  return nil
end

--- The id a `plugins` entry names for a core plugin the old project applies,
--- or nil when the keys already give it or it keeps blocking.
function core_plugins.entry_id(plugin)
  if plugin.core ~= true or core_plugins.KOTLIN_SCRIPT[plugin.type] then return nil end
  local id = core_id(plugin)
  if id == nil or core_plugins.IMPLIED[id] or APPLIED_WITHOUT_AN_ID[id] or KEPT_BLOCKED[id] then return nil end
  return string.sub(id, #CORE_PREFIX + 1)
end

return core_plugins
