daukle.plugin{ api = 1, uses = { "write" },
               requires = { gradle = { url = "https://invalid.example/plugin.lua", sha256 = "0000000000000000000000000000000000000000000000000000000000000000" } } }

local translation = daukle.require("gradle:lib/translation")

daukle.toolchain{ name = "probe", generate = function() return {} end }

local REPOSITORIES = {
  { name = "Marketplace", kind = "maven", url = "https://plugins.example/maven" },
}

local function row(file_name)
  return { kind = "module", component = "com.example:scala:2024.1.25", group = "com.example", module = "scala",
           version = "2024.1.25", fileName = file_name, repository = "Marketplace",
           sha256 = "e320c4785e9d2b3f5e5d29af1a8390cfd33a14c2b97ebabc971d2de17f5ec82f" }
end

local function fresh_state()
  return translation.new{ model = {}, dir = ".", where = "build.gradle" }
end

local function pinned_url(file_name)
  local pin = translation.pin_of(fresh_state(), REPOSITORIES, row(file_name))
  return pin ~= nil and pin.url or "nothing"
end

local function blockers_of(file_names)
  local state = fresh_state()
  for _, file_name in ipairs(file_names) do translation.pin_of(state, REPOSITORIES, row(file_name)) end
  local texts = {}
  for _, found in ipairs(state.blockers) do texts[#texts + 1] = found.construct .. ": " .. found.why end
  return texts
end

local function contains(text, wanted)
  return string.find(text, wanted, 1, true) ~= nil
end

local CHECKS = {
  { "a jar named after its module and version is pinned", function()
    return pinned_url("scala-2024.1.25.jar") == "https://plugins.example/maven/com/example/scala/2024.1.25/scala-2024.1.25.jar"
  end },
  { "a classified jar is pinned", function()
    return pinned_url("scala-2024.1.25-sources.jar")
           == "https://plugins.example/maven/com/example/scala/2024.1.25/scala-2024.1.25-sources.jar"
  end },
  { "a jar a plugin unpacked from its component is not pinned", function()
    return pinned_url("bsp4j-2.1.0-M3.jar") == "nothing"
  end },
  { "it blocks naming the component and the transform", function()
    local texts = blockers_of({ "bsp4j-2.1.0-M3.jar" })
    return #texts == 1 and contains(texts[1], "com.example:scala:2024.1.25: ")
           and contains(texts[1], "artifact transform")
  end },
  { "a component with many such files blocks once", function()
    return #blockers_of({ "bsp4j-2.1.0-M3.jar", "common_2.13-4.5.13.jar" }) == 1
  end },
}

daukle.task{
  name = "probe:report",
  run = function()
    local lines = {}
    for _, check in ipairs(CHECKS) do lines[#lines + 1] = (check[2]() and "ok " or "FAIL ") .. check[1] end
    return daukle.write{ path = "results.txt", text = table.concat(lines, "\n") .. "\n" }
  end,
}
