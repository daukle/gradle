--- Turning the tasks a Gradle plugin CONTRIBUTES into tasks daukle can name.
---
--- A Gradle task can come from a third-party plugin's jar, so only running
--- Gradle can know it exists. That is what makes this different from every
--- other plugin here: a CMake target and an npm script are derivable from the
--- manifest daukle already owns, and a Gradle task is not.
---
--- So the two halves are kept apart. `gradle:discover` runs Gradle and REPORTS
--- what it found; the manifest's `tasks` list is what actually registers one,
--- and it is written by a human like every other key. Nothing generated is read
--- back, which is what stops a project failing every command until its first
--- discovery: a chunk cannot read a file conditionally, so a generated file as
--- the input would have had to exist before the task that creates it ran.

local discovery = {}

--[[ Printed by the generated daukleTasks task, one per line. A prefix rather
     than the bare name because Gradle's own output shares the stream, and
     --quiet does not promise to leave it empty on every version. ]]
discovery.MARKER = "daukle-task "

--- The names this plugin declares itself, which a mapped name may not take.
discovery.STATIC = { classes = true, test = true, jar = true, run = true,
                     version = true, discover = true }

--[[ camelCase to kebab, which is lossy on purpose: core takes lowercase names
     only, so "publishGithub" and "publishgithub" both arrive as
     "publish-github". "processGitHubResources" becomes
     "process-git-hub-resources", which is ugly and correct: an acronym rule
     would be per-plugin knowledge in the one place this design refuses it. ]]
function discovery.task_name(gradle_name)
  return (string.lower((string.gsub(gradle_name, "(%l)(%u)", "%1-%2"))))
end

--- Why a Gradle name cannot become a task name, or nil when it can.
local function refusal_for(gradle_name, task)
  if string.match(task, "^[%l%d%.%_%-]+$") == nil then
    return string.format('"%s" is a Gradle task this toolchain cannot name a task after: a daukle'
                         .. ' task name is lowercase letters, digits, ".", "_" and "-", which'
                         .. ' leaves "%s"', gradle_name, task)
  end
  if discovery.STATIC[task] then
    return string.format('"%s" maps to "gradle:%s", which this toolchain declares itself, and a'
                         .. ' duplicate name is fatal on every command in the project',
                         gradle_name, task)
  end
  return nil
end

--[[ The names a discovery run printed, in the order Gradle gave them.

     @implNote compared with string.sub rather than matched with a pattern: the
     marker holds a bare "-", which is a lazy quantifier in a Lua pattern and
     not a literal, so "^daukle-task (.+)$" matches nothing at all. This
     repository has already shipped that bug once, in
     refuse_a_missing_launcher, and the shape is the same both times: a filter
     that silently passes nothing while everything around it stays green. ]]
function discovery.printed_names(text)
  local names = {}
  local width = #discovery.MARKER
  for line in string.gmatch(text, "[^\r\n]+") do
    if string.sub(line, 1, width) == discovery.MARKER then
      names[#names + 1] = string.sub(line, width + 1)
    end
  end
  if #names == 0 then
    error("Gradle printed no task names at all, so a discovery would record nothing and look"
          .. " like a project whose plugins contribute nothing", 0)
  end
  return names
end

--[[ Real minus baseline, where the baseline is THIS project with its apply
     lines removed rather than a bare one somewhere else. Same source sets, same
     dependencies, same Gradle: what is left over is what the plugins added and
     nothing else. ]]
function discovery.contributed(full, baseline)
  local seen = {}
  for index = 1, #baseline do seen[baseline[index]] = true end
  local names = {}
  for index = 1, #full do
    if not seen[full[index]] then names[#names + 1] = full[index] end
  end
  table.sort(names)
  return names
end

--- @return a list of { gradle, daukle }, refusing a bad or duplicate name.
function discovery.mapped(names)
  if names == nil then return {} end
  if type(names) ~= "table" then
    error('"tasks" must be a list of Gradle task names, not a ' .. type(names), 0)
  end
  local entries, taken = {}, {}
  for index = 1, #names do
    local gradle_name = names[index]
    if type(gradle_name) ~= "string" or gradle_name == "" then
      error('"tasks[' .. index .. ']" is not a Gradle task name', 0)
    end
    local task = discovery.task_name(gradle_name)
    local refusal = refusal_for(gradle_name, task)
    if refusal ~= nil then error(refusal, 0) end
    if taken[task] ~= nil then
      error(string.format('"%s" and "%s" both map to "gradle:%s", and a duplicate task name is'
                          .. ' fatal on every command in the project', taken[task], gradle_name,
                          task), 0)
    end
    taken[task] = gradle_name
    entries[#entries + 1] = { gradle = gradle_name, daukle = task }
  end
  return entries
end

--[[ A REPORT and not an input: nothing reads this back, and it lands in the
     derived directory that `daukle clean` deletes. It shows the name to copy
     beside the name daukle would give it, because the mapping is lossy and a
     user guessing it would guess wrong for an acronym. A name that cannot be
     mapped at all is listed WITH its reason rather than left out, since a task
     missing from a report is indistinguishable from a plugin that contributed
     none. ]]
function discovery.report(names)
  local lines = {
    "# Written by gradle:discover. Nothing reads this back.",
    "#",
    "# Each line is a task your applied plugins contributed, found by running Gradle",
    "# once with the apply lines and once without. Copy the ones you want into",
    "# daukle.toml as [toolchains.gradle] tasks = [ ... ], by their GRADLE name.",
    "#",
    "# gradle name -> daukle task",
  }
  if #names == 0 then
    lines[#lines + 1] = "# (none: no applied plugin contributed a task)"
  end
  for index = 1, #names do
    local task = discovery.task_name(names[index])
    local refusal = refusal_for(names[index], task)
    lines[#lines + 1] = names[index] .. " -> "
                        .. (refusal == nil and ("gradle:" .. task) or ("UNUSABLE, " .. refusal))
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

return discovery
