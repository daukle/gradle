--- The configurations an old build declares itself, found as the names the
--- keys-only generated build lacks, translated into `declaredConfigurations`
--- and compared once the generated build renders them (spec D-203).
local migrate_declared_configurations = {}

local migrate_surface = daukle.require("lib/migrate_surface")
local tables = daukle.require("lib/tables")
local declared_configurations = daukle.require("lib/declared_configurations")

local CONFIGURATIONS_ROW = migrate_surface.CONFIGURATIONS_ROW
local FLAGS = { "canBeResolved", "canBeConsumed", "transitive" }
local UNKNOWN_TASK = "$unknown"

local function by_name(project)
  local configurations = {}
  for _, configuration in ipairs((project or {}).configurations or {}) do
    configurations[configuration.name] = configuration
  end
  return configurations
end

local function blocker(construct, where, why)
  return migrate_surface.blocker(construct, where, why, CONFIGURATIONS_ROW)
end

local function declared_names(old, generated)
  local present = by_name(generated)
  local names = {}
  for _, configuration in ipairs(old.configurations or {}) do
    if present[configuration.name] == nil and not declared_configurations.is_provided(configuration.name) then
      names[#names + 1] = configuration.name
    end
  end
  table.sort(names)
  return names
end

local function extended_by(old, name, declared)
  local users = {}
  for _, configuration in ipairs(old.configurations or {}) do
    if not declared[configuration.name] and tables.as_set(configuration.extendsFrom or {})[name] then
      users[#users + 1] = configuration.name
    end
  end
  table.sort(users)
  return users
end

local function requires_of(old, name, module_of_path, construct, where, blockers)
  local requires = {}
  for _, row in ipairs((old.dependencies or {}).declared or {}) do
    if row.configuration == name then
      local module = row.kind == "project" and module_of_path[row.project] or nil
      if module == nil then
        blockers[#blockers + 1] = blocker(construct, where, "holds " .. (row.project or row.name or row.kind)
          .. ", and a declared configuration takes only projects of this build so far")
      elseif row.targetConfiguration ~= nil then
        requires[#requires + 1] = { module = module, configuration = row.targetConfiguration }
      else
        requires[#requires + 1] = module
      end
    end
  end
  return requires
end

local function artifacts_of(configuration, generated_tasks, construct, where, blockers)
  local tasks = configuration.artifactTasks
  if type(tasks) ~= "table" or tasks["$unrendered"] ~= nil then
    blockers[#blockers + 1] = blocker(construct, where, "has artifacts the model could not read")
    return {}
  end
  local artifacts = {}
  for _, task in ipairs(tasks) do
    if task == UNKNOWN_TASK then
      blockers[#blockers + 1] = blocker(construct, where, "has an artifact no task builds, which no key can say")
    elseif generated_tasks[task] then
      artifacts[#artifacts + 1] = task
    end
  end
  return artifacts
end

local function is_placed(place)
  return place.build ~= nil or place.module ~= nil or place.root == true
end

local function task_names(project)
  local names = {}
  for _, task in ipairs((project or {}).tasks or {}) do names[task.name] = true end
  return names
end

local function translated(old, generated, configuration, declared, module_of_path, where, blockers)
  local construct = "configurations." .. configuration.name
  if #(configuration.attributes or {}) > 0 then
    blockers[#blockers + 1] = blocker(construct, where, "sets attributes ("
      .. table.concat(configuration.attributes, ", ") .. "), which no declaredConfigurations key can say")
  end
  local block = {}
  local extends = {}
  for _, base in ipairs(configuration.extendsFrom or {}) do extends[#extends + 1] = base end
  if #extends > 0 then block.extendsFrom = extends end
  local users = extended_by(old, configuration.name, declared)
  if #users > 0 then block.extendedBy = users end
  local requires = requires_of(old, configuration.name, module_of_path, construct, where, blockers)
  if #requires > 0 then block.requires = requires end
  local artifacts = artifacts_of(configuration, task_names(generated), construct, where, blockers)
  if #artifacts > 0 then block.artifacts = artifacts end
  for _, flag in ipairs(FLAGS) do
    if configuration[flag] == false then block[flag] = false end
  end
  return block
end

--- @param targets every project a key can be set for, as lib/migrate_carry lists them
--- @param module_of_path a main-build project's Gradle path to its daukle module name
--- @param block_at the config block a target's place names, created when missing
--- @return the declared names by target label, and the blockers
function migrate_declared_configurations.translate(targets, module_of_path, block_at)
  local declared_by_label, blockers = {}, {}
  for _, target in ipairs(targets) do
    if target.counterpart ~= nil and is_placed(target.place) then
      local names = declared_names(target.project, target.counterpart)
      if #names > 0 then
        local declared = tables.as_set(names)
        local old = by_name(target.project)
        local value = {}
        for _, name in ipairs(names) do
          value[name] = translated(target.project, target.counterpart, old[name], declared, module_of_path,
                                   target.where, blockers)
        end
        block_at(target.place).declaredConfigurations = value
        declared_by_label[target.label] = names
      end
    end
  end
  return declared_by_label, blockers
end

local function same_list(left, right)
  return tables.deep_equal(left or {}, right or {})
end

--- What the generated build renders differently for each configuration the
--- old build declared: missing, wired otherwise, or flagged otherwise.
function migrate_declared_configurations.differences(targets, declared_by_label)
  local blockers = {}
  for _, target in ipairs(targets) do
    local names = declared_by_label[target.label]
    if names ~= nil and target.counterpart ~= nil then
      local old, generated = by_name(target.project), by_name(target.counterpart)
      for _, name in ipairs(names) do
        local construct = "configurations." .. name
        local mine = generated[name]
        if mine == nil then
          blockers[#blockers + 1] = blocker(construct, target.where, "is declared by the old build and missing"
                                            .. " from the build daukle/gradle generates")
        elseif not same_list(old[name].extendsFrom, mine.extendsFrom) then
          blockers[#blockers + 1] = blocker(construct, target.where, "extends "
            .. table.concat(old[name].extendsFrom or {}, ", ") .. " in the old build and "
            .. table.concat(mine.extendsFrom or {}, ", ") .. " in the generated one")
        else
          for _, flag in ipairs(FLAGS) do
            if old[name][flag] ~= mine[flag] then
              blockers[#blockers + 1] = blocker(construct, target.where, "has " .. flag .. " "
                .. tostring(old[name][flag]) .. " in the old build and " .. tostring(mine[flag])
                .. " in the generated one")
            end
          end
        end
      end
    end
  end
  return blockers
end

return migrate_declared_configurations
