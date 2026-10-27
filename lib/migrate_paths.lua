--- The paths a migration names: the project's, relative to the directory
--- migrate runs in, and the instance's derived directory.
local migrate_paths = {}

local carried = daukle.require("lib/carried")

--- Gradle's project cache for every run against the old build, which keeps
--- its `.gradle/` out of the project.
migrate_paths.PROJECT_CACHE = carried.MIGRATE_PREFIX .. "cache"

function migrate_paths.within(dir, name)
  if dir == nil or dir == "." then return name end
  return dir .. "/" .. name
end

function migrate_paths.derived(context, name)
  return "build/daukle/" .. context.instance .. "/" .. name
end

--- The derived directory as Gradle must be told it.
---
--- @implNote relative to the instance's own directory, not to the process's:
--- `--project-dir` also moves Gradle's current directory, and Gradle resolves
--- `--init-script` and `--project-cache-dir` against that.
function migrate_paths.derived_from_instance(context, name)
  local climb = ""
  for segment in string.gmatch(context.dir or "", "[^/]+") do
    if segment ~= "." then climb = climb .. "../" end
  end
  return climb .. migrate_paths.derived(context, name)
end

function migrate_paths.has_entry(directory, name, kind)
  for _, entry in ipairs(daukle.list(directory) or {}) do
    if entry.name == name and entry.kind == kind then return true end
  end
  return false
end

function migrate_paths.has_file(directory, name)
  return migrate_paths.has_entry(directory, name, "file")
end

--- Whether a path the model gives stays below the directory it is relative
--- to: not absolute, no drive, no parent segment.
function migrate_paths.is_below(path)
  if path == nil or path == "" or string.sub(path, 1, 1) == "/" or string.find(path, ":", 1, true) then
    return false
  end
  for segment in string.gmatch(path, "[^/]+") do
    if segment == ".." then return false end
  end
  return true
end

return migrate_paths
