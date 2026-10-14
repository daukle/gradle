--- The fragments a composite build adds to the files Gradle reads.
local composite = {}

local groovy = daukle.require("lib/groovy")

composite.INCLUDED_DIR = "included"
composite.GROUP = "daukle.included"

function composite.path_of(name)
  return composite.INCLUDED_DIR .. "/" .. name
end

function composite.plugins_block(ids)
  if #ids == 1 then return { "plugins { id " .. groovy.quoted(ids[1]) .. " }" } end
  local lines = { "plugins {" }
  for index = 1, #ids do lines[#lines + 1] = "  id " .. groovy.quoted(ids[index]) end
  lines[#lines + 1] = "}"
  return lines
end

--- @implNote each plugin is created under an index name rather than its id,
--- because an id may hold characters a Groovy identifier cannot.
function composite.gradle_plugin_block(plugins)
  local lines = { "gradlePlugin {", "  plugins {" }
  for index = 1, #plugins do
    lines[#lines + 1] = "    create('plugin" .. index .. "') {"
    lines[#lines + 1] = "      id = " .. groovy.quoted(plugins[index].id)
    lines[#lines + 1] = "      implementationClass = "
                        .. groovy.quoted(plugins[index].implementationClass)
    lines[#lines + 1] = "    }"
  end
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return lines
end

return composite
