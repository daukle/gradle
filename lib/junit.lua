--- Why this exists: Gradle 9 stopped supplying the JUnit Platform launcher and
--- nothing else will supply it either.
---
--- Gradle 8 injected `junit-platform-launcher` into a test runtime classpath by
--- itself and 9 removed that, so a generated build that declares its
--- dependencies as file paths passes on 8.13 with a deprecation and FAILS on
--- 9.6.0 with "Failed to load JUnit Platform ... including the JUnit Platform
--- launcher". The launcher is in no POM graph, so no resolver produces it: it
--- has to be asked for by name.
---
--- @implNote this plugin deliberately pins NO launcher of its own, which the
--- D-90 spec originally proposed. Measured: a 1.14.4 launcher against a 1.10.1
--- platform engine dies with
--- `NoClassDefFoundError: org/junit/platform/engine/OutputDirectoryCreator`, so
--- a launcher is NOT forward compatible with an older engine and one pinned
--- default would be wrong for every project not on that exact platform. The
--- version is read off the engine the project already resolved instead, and the
--- refusal names the coordinate to add.

local junit = {}

local ENGINE = "junit-platform-engine"
local LAUNCHER = "junit-platform-launcher"

--- The version of `artifact` among these classpath entries, or nil.
---
--- Read from the URL rather than from `as`, because a repository lays an
--- artifact out as `<group>/<artifact>/<version>/<artifact>-<version>.jar`
--- while `as` is a label a hand-written entry may spell any way at all.
--- @implNote the artifact name is escaped before it reaches `match`. A bare
--- `-` in a Lua pattern is a LAZY QUANTIFIER, not a literal, so the pattern
--- built from "junit-platform-engine" matched nothing at all and the refusal
--- below silently never fired. It was found by running it, not by reading it.
local function literal(text)
  return (text:gsub("(%W)", "%%%1"))
end

local function version_of(entries, artifact)
  local name = literal(artifact)
  for index = 1, #entries do
    local url = entries[index].url
    if type(url) == "string" then
      local version = url:match("/" .. name .. "/([^/]+)/" .. name .. "%-")
      if version ~= nil then return version end
    end
  end
  return nil
end

junit.version_of = version_of

--- Refuses a test run whose platform engine has no matching launcher.
---
--- It refuses on every Gradle version rather than only on 9, because the same
--- declaration that fails on 9 merely warns on 8, and shipping a project whose
--- tests stop running at the next Gradle major is the thing this refusal is
--- for. The fix is one line in the manifest.
function junit.refuse_a_missing_launcher(entries)
  local engine = version_of(entries, ENGINE)
  if engine == nil then return end
  if version_of(entries, LAUNCHER) ~= nil then return end
  error('the test classpath carries ' .. ENGINE .. ' ' .. engine .. ' and no ' .. LAUNCHER
        .. '. Gradle 8 used to supply one and Gradle 9 does not, so this build would pass here'
        .. ' and fail on the next Gradle major. It is in no POM, so no resolver finds it: add'
        .. ' "org.junit.platform:' .. LAUNCHER .. ':' .. engine .. '" to the test coordinates'
        .. ' your resolver reads, at the SAME version as the engine', 0)
end

return junit
