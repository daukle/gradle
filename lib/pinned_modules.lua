--- The modules a project's pinned entries already hold, which a plugin may
--- declare again by coordinate while it configures (Kotlin's `kotlin-stdlib`):
--- the generated build declares no repository, so such a dependency is
--- dropped where a pinned file of the same module and version is present
--- (spec D-214), and the comparison proves the classpaths equal.
local pinned_modules = {}

local configurations = daukle.require("lib/configurations")
local groovy = daukle.require("lib/groovy")
local tables = daukle.require("lib/tables")

--- `<module>:<version>` from a Maven-layout url, `.../<module>/<version>/<file>`, or nil.
local function coordinate_of(url)
  if type(url) ~= "string" then return nil end
  local module, version = string.match(url, "/([^/]+)/([^/]+)/[^/]+$")
  if module == nil then return nil end
  return module .. ":" .. version
end

local function add_entries(found, entries)
  for _, entry in ipairs(entries or {}) do
    local coordinate = coordinate_of(entry.url)
    if coordinate ~= nil then found[coordinate] = true end
  end
end

--- Every `<module>:<version>` the configuration keys and named configurations pin.
function pinned_modules.of(entries, named)
  local found = {}
  for _, row in ipairs(configurations.all) do add_entries(found, entries[row.key]) end
  for _, configuration in ipairs(named or {}) do add_entries(found, configuration.entries) end
  return tables.sorted_keys(found)
end

--- The lines that drop a declared external dependency a pinned file already holds, or none.
function pinned_modules.lines(coordinates)
  if coordinates == nil or #coordinates == 0 then return {} end
  local quoted = {}
  for index, coordinate in ipairs(coordinates) do quoted[index] = groovy.quoted(coordinate) end
  return {
    "def daukleHeldByPins = [" .. table.concat(quoted, ", ") .. "] as Set",
    "configurations.configureEach {",
    "  withDependencies { dependencies ->",
    "    dependencies.removeIf { it instanceof ExternalModuleDependency && daukleHeldByPins.contains(it.name + ':' + it.version) }",
    "  }",
    "}",
    "",
  }
end

return pinned_modules
