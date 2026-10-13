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
  ["7.6.4"] = "bed1da33cca0f557ab13691c77f38bb67388119e4794d113e051039b80af9bb1",
  ["8.4"] = "3e1af3ae886920c3ac87f7a91f816c0c7c436f276a6eefdb3da152100fef72ae",
  ["8.8"] = "a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612",
  ["8.10"] = "5b9c5eb3f9fc2c94abaea57d90bd78747ca117ddbbf96c859d3741181a12bf2a",
  ["8.10.2"] = "31c55713e40233a8303827ceb42ca48a47267a0ad4bab9177123121e71524c26",
  ["8.11.1"] = "f397b287023acdba1e9f6fc5ea72d22dd63669d59ed4a289a29b1a76eee151c6",
  ["8.13"] = "20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78",
  ["8.14"] = "61ad310d3c7d3e5da131b76bbf22b5a4c0786e9d892dae8c1658d4b484de3caa",
  ["8.14.3"] = "bd71102213493060956ec229d946beee57158dbd89d0e62b91bca0fa2c5f3531",
  ["8.14.4"] = "f1771298a70f6db5a29daf62378c4e18a17fc33c9ba6b14362e0cdf40610380d",
  ["9.0.0"] = "8fad3d78296ca518113f3d29016617c7f9367dc005f932bd9d93bf45ba46072b",
  ["9.1.0"] = "a17ddd85a26b6a7f5ddb71ff8b05fc5104c0202c6e64782429790c933686c806",
  ["9.2.0"] = "df67a32e86e3276d011735facb1535f64d0d88df84fa87521e90becc2d735444",
  ["9.3.1"] = "b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06",
  ["9.5.0"] = "553c78f50dafcd54d65b9a444649057857469edf836431389695608536d6b746",
  ["9.6.0"] = "bbaeb2fef8710818cf0e261201dab964c572f92b942812df0c3620d62a529a01",
}

--[[ A default is only compatible with this project's reproducibility stance
     because it moves with a RELEASE of this plugin and never on its own: a
     given plugin version always provisions the same Gradle. Same argument
     daukle/java's lib/jdks.lua makes for its default JDK.

     8 rather than 9 was decided when 8 was the majority, MEASURED 2026-10-06
     over 190 gradle-wrapper.properties: 106 on 8.x against 84 on 9.x. ON THE
     LIVE POPULATION THAT HAS INVERTED, re-measured 2026-10-13 over the 158 that
     exclude archived and sandbox: 83 on 9.x against 73 on 8.x. So the reason
     written here is SPENT, and the default is left at 8.13 deliberately rather
     than by inheritance: moving it changes what every project declaring no
     version builds with, which is a decision of its own and not a side effect
     of pinning more rows.

     The second reason it gave is spent too rather than wrong: 9 removed the
     automatic JUnit Platform launcher, and this plugin now pins one itself, so
     9 is served and not avoided. ]]
local DEFAULT = "8.13"

--- @implNote numeric per component rather than table.sort's string order, which
--- reads "8.10, 8.13, 8.14, 8.4" and puts the oldest pin last. It is also what
--- decides whether a refused version is BELOW the range or outside it, and the
--- two answers need different sentences.
local function precedes(left, right)
  local function components(version)
    local numbers = {}
    for piece in version:gmatch("[^.]+") do numbers[#numbers + 1] = tonumber(piece) or 0 end
    return numbers
  end
  local one, two = components(left), components(right)
  for index = 1, math.max(#one, #two) do
    local first, second = one[index] or 0, two[index] or 0
    if first ~= second then return first < second end
  end
  return false
end

local function ascending()
  local versions = {}
  for version in pairs(DIGESTS) do versions[#versions + 1] = version end
  table.sort(versions, precedes)
  return versions
end

local function known()
  return table.concat(ascending(), ", ")
end

local function oldest()
  return ascending()[1]
end

--- Why the range stops where it does, appended when a refused version is below
--- the oldest pin.
---
--- @implNote deliberately NOT "an older Gradle cannot run on JDK 17", which is
--- false of 7.3 through 7.6.3: those run on 17 and are unpinned only because
--- nothing asked for them. 6.7 is what was measured. The number is
--- daukle/java's table, so an older JDK row there lowers this floor and changes
--- this sentence with it.
local function why_the_range_stops(floor)
  return ". Nothing below " .. floor .. " is pinned: Gradle 6.7 cannot run on JDK 17, the oldest"
         .. " daukle/java provisions, and the versions in between are pinnable and simply unmeasured"
end

local function for_version(version)
  version = version or DEFAULT
  if type(version) ~= "string" then
    error('"version" must be a Gradle version such as "8.13", not a ' .. type(version), 0)
  end
  local digest = DIGESTS[version]
  if digest == nil then
    local floor = oldest()
    local why = precedes(version, floor) and why_the_range_stops(floor) or ""
    error('no pinned Gradle "' .. version .. '". This plugin pins ' .. known()
          .. ', and a version it does not pin is a version it cannot verify' .. why, 0)
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
