--- The tools a Gradle plugin downloads by default, asked of Gradle rather than kept in a table:
--- a table would be per plugin and per Gradle version, and this plugin knows no plugin by name.

local tool_defaults = {}

tool_defaults.SCRIPT = "tools.gradle"

local MARKER = "daukle-tool "

--- An init script printing, per project, `<marker><path>`, then one
--- `<marker><path> <configuration> <group>:<name>:<version>` per default coordinate.
---
--- @implNote the declared sets are read BEFORE any `incoming`, because reading `incoming` runs a
--- configuration's default action, which fills its declared set: read after, every one is non-empty.
--- @implNote a coordinate an ancestor in the `hierarchy` also reports is the ancestor's, not this
--- configuration's, so a classpath extending a tool configuration does not repeat its default.
--- @implNote an included build or `buildSrc` has a parent, and its root project also has path `:`,
--- so reporting it would merge its lines into the main root's entry.
--- @implNote `canBeDeclared` exists from Gradle 8.2. Measured on 9.6.0, a core plugin reports a
--- default on `compileClasspath`, which no build may declare a dependency against.
tool_defaults.SCRIPT_TEXT = table.concat({
  "gradle.projectsEvaluated {",
  "  if (gradle.parent != null) return",
  "  gradle.rootProject.allprojects { project ->",
  "    println '" .. MARKER .. "' + project.path",
  "    def resolvable = project.configurations.toList().findAll { it.canBeResolved }",
  "    def undeclared = resolvable.findAll { it.dependencies.isEmpty() }.collect { it.name } as Set",
  "    def declarable = { configuration ->",
  "      !configuration.metaClass.respondsTo(configuration, 'isCanBeDeclared') || configuration.canBeDeclared",
  "    }",
  "    def reported = [:]",
  "    resolvable.each { configuration ->",
  "      reported[configuration.name] = configuration.incoming.dependencies",
  "        .withType(org.gradle.api.artifacts.ExternalModuleDependency)",
  "        .findAll { it.group != null && it.version != null && !it.version.isEmpty() }",
  "        .collect { it.group + ':' + it.name + ':' + it.version } as Set",
  "    }",
  "    resolvable.findAll { undeclared.contains(it.name) && declarable(it) }.each { configuration ->",
  "      def own = new TreeSet(reported[configuration.name])",
  "      configuration.hierarchy.each { parent ->",
  "        if (parent != configuration && reported.containsKey(parent.name)) own.removeAll(reported[parent.name])",
  "      }",
  "      own.each { println '" .. MARKER .. "' + project.path + ' ' + configuration.name + ' ' + it }",
  "    }",
  "  }",
  "}",
  "",
}, "\n")

local function fields_of(line)
  local fields = {}
  for field in string.gmatch(line, "%S+") do fields[#fields + 1] = field end
  return fields
end

--- @return { [project path] = { [configuration] = { coordinate... } } }
--- @implNote compared with string.sub, not a pattern: the marker's "-" is a quantifier in one.
--- A run that printed no project line at all is refused, because it would read as a project
--- whose plugins download nothing and write an empty file over the pins.
function tool_defaults.reported(text)
  local projects = {}
  local width = #MARKER
  for line in string.gmatch(text, "[^\r\n]+") do
    if string.sub(line, 1, width) == MARKER then
      local fields = fields_of(string.sub(line, width + 1))
      local project = fields[1]
      projects[project] = projects[project] or {}
      if #fields == 3 then
        local listed = projects[project][fields[2]] or {}
        listed[#listed + 1] = fields[3]
        projects[project][fields[2]] = listed
      end
    end
  end
  if next(projects) == nil then
    error("Gradle printed no project at all, so resolving its tools would write an empty file"
          .. " over the pins as if no plugin downloaded anything", 0)
  end
  return projects
end

local function add_named(names, block)
  if type(block) ~= "table" or type(block.configurations) ~= "table" then return end
  for name in pairs(block.configurations) do names[name] = true end
end

local function add_into(names, maven, target)
  if type(maven) ~= "table" or type(maven.resolve) ~= "table" then return end
  for _, entry in ipairs(maven.resolve) do
    local into = type(entry) == "table" and entry.into or nil
    if type(into) == "table" and (entry["for"] or maven["for"]) == target and #into >= 2
       and into[#into - 1] == "configurations" then
      names[into[#into]] = true
    end
  end
end

--- The configuration names the user fills on purpose: set under `configurations` anywhere in the
--- manifest, or named by the `into` of a `[[toolchains.maven.resolve]]` entry for this toolchain.
---
--- @implNote by name across every scope, so a configuration one module fills by hand is left alone
--- in all of them rather than pinned beside it. Read from `daukle.toml`, never the merged config,
--- which carries the file this task writes and would make every pin look hand-written.
function tool_defaults.user_filled(manifest, target)
  local names = {}
  local toolchains = type(manifest) == "table" and manifest.toolchains or nil
  if type(toolchains) ~= "table" then return names end
  local gradle = toolchains[target]
  if type(gradle) == "table" then
    add_named(names, gradle)
    for _, scope in ipairs({ "modules", "builds" }) do
      if type(gradle[scope]) == "table" then
        for _, block in pairs(gradle[scope]) do add_named(names, block) end
      end
    end
  end
  add_into(names, toolchains.maven, target)
  return names
end

local function add_unrecognised(names, block, generated)
  if type(block) ~= "table" or type(block.configurations) ~= "table" then return end
  for name, entries in pairs(block.configurations) do
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
      if type(entry) == "table" and type(entry.url) == "string"
         and not string.find(generated, entry.url, 1, true) then
        names[name] = true
      end
    end
  end
end

--- The configuration names the merged config holds a pin for that the previously generated
--- `tools.lua` does not hold, which are pins written by hand in `daukle.lua`.
---
--- @implNote told apart by url, since the merged config does not say which file a pin came from.
--- Maven's renderer appends, so a name filled by hand and by this task would hold two closures.
function tool_defaults.hand_pinned(config, generated)
  local names = {}
  add_unrecognised(names, config, generated)
  for _, scope in ipairs({ "modules", "builds" }) do
    if type(config[scope]) == "table" then
      for _, block in pairs(config[scope]) do add_unrecognised(names, block, generated) end
    end
  end
  return names
end

local function roots_of(coordinates)
  local roots = {}
  for index = 1, #coordinates do
    local group, artifact, version = string.match(coordinates[index], "^([^:]+):([^:]+):(.+)$")
    roots[index] = { group = group, artifact = artifact, version = version }
  end
  return roots
end

local function same_list(left, right)
  return right ~= nil and table.concat(left, " ") == table.concat(right, " ")
end

--- Project-wide only when every module reports the same coordinates: a project-wide pin is
--- rendered into every module, and a module whose plugins lack the configuration fails on it.
local function shared_coordinates(reported, projects, name)
  local first = (reported[projects[1]] or {})[name]
  if first == nil then return nil end
  for index = 2, #projects do
    if not same_list(first, (reported[projects[index]] or {})[name]) then return nil end
  end
  return first
end

local function names_of(reported, projects, skipped)
  local seen, names = {}, {}
  for _, project in ipairs(projects) do
    for name in pairs(reported[project] or {}) do
      if not seen[name] and not skipped[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

--- The resolutions `daukle/maven`'s `pinned_groups` takes, one per configuration and scope.
---
--- @param options { target, repository, strategy, modules = { name... }, path_of = function(name) }
--- where `path_of` maps a module name to its Gradle project path; no modules is the root project.
function tool_defaults.resolutions(reported, skipped, options)
  local modules = options.modules
  local projects = { ":" }
  if #modules > 0 then
    projects = {}
    for index = 1, #modules do projects[index] = options.path_of(modules[index]) end
  end
  local resolutions = {}
  local function add(path, coordinates)
    resolutions[#resolutions + 1] = { target = options.target, repository = options.repository,
                                      strategy = options.strategy, path = path,
                                      roots = roots_of(coordinates) }
  end
  for _, name in ipairs(names_of(reported, projects, skipped)) do
    local shared = shared_coordinates(reported, projects, name)
    if shared ~= nil then
      add({ "configurations", name }, shared)
    else
      for index = 1, #modules do
        local own = (reported[projects[index]] or {})[name]
        if own ~= nil then add({ "modules", modules[index], "configurations", name }, own) end
      end
    end
  end
  return resolutions
end

--- Raises one message naming every dependency a resolution reached with no version, and the
--- configuration it belongs to, because a closure missing one is a tool that fails at run time.
---
--- @param skipped_of function(resolution) returning the skipped dependency descriptions
function tool_defaults.refuse_skipped(resolutions, skipped_of)
  local lines = {}
  for _, resolution in ipairs(resolutions) do
    for _, skipped in ipairs(skipped_of(resolution)) do
      lines[#lines + 1] = skipped .. " (configuration " .. table.concat(resolution.path, ".") .. ")"
    end
  end
  if #lines > 0 then
    error("the closure of a tool skipped " .. #lines .. " dependenc" .. (#lines == 1 and "y" or "ies")
          .. " that no POM gives a version, so the tool would fail when it runs and nothing was"
          .. " written: " .. table.concat(lines, "; "), 0)
  end
end

return tool_defaults
