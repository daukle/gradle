--- Which Gradle a declared version resolves to, and the digest it is pinned by.
---
--- @implNote a Gradle distribution is ONE archive for every platform, which is
--- why this table is keyed on the version alone where lib/jdks.lua in
--- daukle/java needs a row per host. The "-bin" distribution is the one without
--- the documentation and samples, and is what every gradlew in this tree
--- fetches.

-- Transcribed from the .sha256 gradle.org publishes beside each asset. NEVER
-- computed from a file on disk, for the reason lib/jdks.lua gives: a digest
-- taken from a working tree is a digest of whatever the checkout did to it.
--
-- Unlike Maven Central, which publishes .jar.sha256 for none of the twenty
-- artifacts D-77 measured, gradle.org publishes one for every distribution. So
-- a Gradle is pinned the easy way and nothing here needs --resolve.
local DIGESTS = {
  ["8.13"] = "20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78",
  ["8.14.4"] = "f1771298a70f6db5a29daf62378c4e18a17fc33c9ba6b14362e0cdf40610380d",
  ["9.6.0"] = "bbaeb2fef8710818cf0e261201dab964c572f92b942812df0c3620d62a529a01",
}

--[[ A default is only compatible with this project's reproducibility stance
     because it moves with a RELEASE of this plugin and never on its own: a
     given plugin version always provisions the same Gradle. Same argument
     daukle/java's lib/jdks.lua makes for its default JDK.

     8 rather than 9, because every Gradle project measured in this tree is on
     8 and because 9 removed the automatic JUnit Platform launcher that a
     generated build has to supply for itself. ]]
local DEFAULT = "8.13"

local function known()
  local versions = {}
  for version in pairs(DIGESTS) do versions[#versions + 1] = version end
  table.sort(versions)
  return table.concat(versions, ", ")
end

local function for_version(version)
  version = version or DEFAULT
  if type(version) ~= "string" then
    error('"version" must be a Gradle version such as "8.13", not a ' .. type(version), 0)
  end
  local digest = DIGESTS[version]
  if digest == nil then
    error('no pinned Gradle "' .. version .. '". This plugin pins ' .. known()
          .. ', and a version it does not pin is a version it cannot verify', 0)
  end
  return {
    version = version,
    url = "https://services.gradle.org/distributions/gradle-" .. version .. "-bin.zip",
    sha256 = digest,
    -- The unpacker strips no leading component, so every path into the
    -- distribution carries the archive's own directory.
    home = "gradle-" .. version,
  }
end

return { for_version = for_version, default = DEFAULT, known = known }
