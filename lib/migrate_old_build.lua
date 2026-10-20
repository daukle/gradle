--- The old build's side of the proof: its own jar tasks, run on the Gradle
--- the wrapper pins and on the JDK the new manifest's tasks run on, each jar
--- copied into the derived directory.
local migrate_old_build = {}

local launcher = daukle.require("lib/launcher")
local distributions = daukle.require("lib/distributions")
local migrate_jars = daukle.require("lib/migrate_jars")
local migrate_paths = daukle.require("lib/migrate_paths")

local derived_from_instance = migrate_paths.derived_from_instance

local INIT_SCRIPT = "migrate-old-build.gradle"
local PLAN_PROPERTY = "daukle.migrate.jars"
local JDK_PROPERTY = "daukle.migrate.jdk"
local STDERR_SHOWN = 2000
local SURFACE = "GRADLE-SURFACE.md: "
local JAVA_ROW = SURFACE .. "3. The `java` extension and source layout"

--- Registers, in each project the plan names, one Copy task per planned jar
--- task, and refuses a run in which any JavaCompile would use another JDK
--- than the provisioned one.
---
--- @implNote a Copy task rather than an action added to the jar task: an
--- added action reruns nothing once the jar is up to date, so a jar deleted
--- from the derived directory would never come back.
--- @implNote the plan's paths are relative to the directory migrate runs
--- Gradle in, which is the outermost build's current directory.
migrate_old_build.SCRIPT = [==[
def PLAN_PROPERTY = 'daukle.migrate.jars'
def JDK_PROPERTY = 'daukle.migrate.jdk'
def COPY_TASK_PREFIX = 'daukleMigrateOld'

def outermost = gradle
while (outermost.parent != null) outermost = outermost.parent

def requested = { String name ->
  def value = outermost.startParameter.systemPropertiesArgs[name] ?: System.getProperty(name)
  if (value == null) throw new GradleException(name + ' is not set, so the old build has no plan to run')
  value
}

def resolved = { String path ->
  def file = new File(path)
  (file.isAbsolute() ? file : new File(outermost.startParameter.currentDir, path)).canonicalFile
}

def copyTaskOf = { String name -> COPY_TASK_PREFIX + name.substring(0, 1).toUpperCase() + name.substring(1) }

gradle.projectsEvaluated {
  def rows = resolved(requested(PLAN_PROPERTY)).readLines('UTF-8')*.split('\t', -1).findAll { it[0] == 'jar' }
  gradle.rootProject.allprojects.each { project ->
    def directory = project.projectDir.canonicalFile
    rows.findAll { resolved(it[2]) == directory }.each { row ->
      def jar = project.tasks.named(row[3])
      def into = resolved(row[4])
      project.tasks.register(copyTaskOf(row[3]), Copy) { copy ->
        copy.from(jar)
        copy.into(into)
      }
    }
  }
}

gradle.taskGraph.whenReady { graph ->
  def jdk = resolved(requested(JDK_PROPERTY))
  graph.allTasks.findAll { it instanceof org.gradle.api.tasks.compile.JavaCompile }.each { task ->
    def compiler = task.javaCompiler.getOrNull()
    def home = compiler == null ? new File(System.getProperty('java.home')) : compiler.metadata.installationPath.asFile
    if (home.canonicalFile != jdk) {
      throw new GradleException(task.path + ' compiles with the JDK at ' + home + ', not with ' + jdk
                                + ', the one the new build compiles with, so its jar would compare two JDKs')
    }
  }
}
]==]

local function tail(text)
  if #text <= STDERR_SHOWN then return text end
  return "..." .. string.sub(text, -STDERR_SHOWN)
end

local FIRST_GRADLE_PROPERTY_TOOLCHAINS = "9.2.0"

--- The toolchain settings that leave the provisioned JDK the only one, as
--- the Gradle in use reads them.
---
--- @implNote measured with a toolchain of 21 and the paths naming daukle's
--- JDK 21: 7.6.4, 8.13, 9.0.0 and 9.1.0 ignore `-D` and resolve the user's
--- own `~/.gradle/jdks` install, while 9.2.0 to 9.6.0 honour it; `-P` works
--- everywhere but is deprecated on 9.x and makes Gradle write a problems
--- report into the project's own `build/reports`.
local function toolchain_arguments(gradle_version, jdk_home)
  local flag = "-P"
  if not distributions.precedes(gradle_version or distributions.default, FIRST_GRADLE_PROPERTY_TOOLCHAINS) then
    flag = "-D"
  end
  return { flag .. "org.gradle.java.installations.auto-detect=false",
           flag .. "org.gradle.java.installations.auto-download=false",
           flag .. "org.gradle.java.installations.paths=" .. jdk_home }
end

--- @implNote auto-detection and auto-download are off and the provisioned
--- JDK is the only installation, so a toolchain the build declares resolves
--- to it or fails; the init script then checks every compile task anyway,
--- because a build can also name a compiler per task.
local function arguments_of(context, plan, jdk_home)
  local arguments = {
    "--project-dir", ".",
    "--project-cache-dir", derived_from_instance(context, migrate_paths.PROJECT_CACHE),
    "--no-configuration-cache",
    "--init-script", derived_from_instance(context, INIT_SCRIPT),
    "-D" .. PLAN_PROPERTY .. "=" .. derived_from_instance(context, migrate_jars.PLAN),
    "-D" .. JDK_PROPERTY .. "=" .. jdk_home,
    "--quiet",
  }
  for _, argument in ipairs(toolchain_arguments(plan.gradle, jdk_home)) do arguments[#arguments + 1] = argument end
  for _, task in ipairs(plan.tasks) do arguments[#arguments + 1] = task end
  return arguments
end

--- The migrator's `build`: the old jars the proof compares, from the plan
--- `run` wrote.
function migrate_old_build.build(context)
  local plan = migrate_jars.read_plan(context)
  daukle.write{ path = INIT_SCRIPT, text = migrate_old_build.SCRIPT }
  local jdk_home = launcher.jdk_home(context, plan.jdk)
  local result = launcher.run(context, plan.gradle, plan.jdk, arguments_of(context, plan, jdk_home),
                              { cwd = context.dir or ".", capture = true, check = false })
  if result.code ~= 0 then
    error("Gradle could not build the old jars:\n" .. tail(result.stderr), 0)
  end
end

--- The dumped `java.toolchain`, or nil when the project has no `java` extension.
local function toolchain_of(project)
  local java = ((project.extensions or {}).java or {}).value
  if type(java) ~= "table" or type(java.toolchain) ~= "table" then return nil end
  return java.toolchain
end

--- What each constraint reads as when the build set none, as Gradle writes
--- it: measured on 7.6.4 (`any`), 8.13 and 9.6.0 (`any vendor`); an
--- unmeasured spelling blocks rather than passes.
local CONSTRAINTS = {
  { key = "vendor", unconstrained = { ["any"] = true, ["any vendor"] = true }, picks = "a vendor" },
  { key = "implementation", unconstrained = { ["vendor-specific"] = true }, picks = "an implementation" },
}

local function described(value)
  if type(value) == "string" then return value end
  return "a value the dump could not read"
end

--- A toolchain that asks for more than a language version: the old build is
--- pointed at the one JDK daukle provisions, and a vendor or an
--- implementation that JDK may not be would fail it rather than compare it.
--- A value the dump could not read blocks as well.
function migrate_old_build.toolchain_blockers(project, where)
  local toolchain = toolchain_of(project)
  local blockers = {}
  if toolchain == nil then return blockers end
  for _, constraint in ipairs(CONSTRAINTS) do
    if not constraint.unconstrained[toolchain[constraint.key]] then
      blockers[#blockers + 1] = { construct = "java.toolchain." .. constraint.key, where = where, surface = JAVA_ROW,
                                  why = "asks for " .. described(toolchain[constraint.key]) .. ", and the proof"
                                        .. " builds the old jars on the one JDK daukle provisions, which no key"
                                        .. " picks " .. constraint.picks .. " for" }
    end
  end
  return blockers
end

return migrate_old_build
