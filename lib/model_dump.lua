--- The init script that writes a Gradle build's evaluated model as JSON.
---
--- @implNote the dump runs at `gradle.taskGraph.whenReady`, because a value a
--- build sets in its own `projectsEvaluated` is not yet visible in the init
--- script's. Core plugins' values come from typed readers (the `java`,
--- `sourceSets` and `application` extensions, and the `Jar`, `JavaCompile`,
--- `Test`, `Javadoc` and `JavaExec` tasks), because a generic walk renders
--- Gradle 9's `JavaLanguageVersion` as internal fields; the walk, bounded by a
--- depth and a budget, is for third-party extensions only, since walking every
--- extension of a 51-project build ran over 20 minutes. A task is build logic
--- when its type or an action's class was loaded by a script's class loader
--- (`groovy-script-<file>-loader`, `kotlin-dsl:<file>.kts:`), the one signal
--- that finds a Groovy script's top-level task class as well as a closure and
--- a Kotlin lambda. In a composite the script runs once per build and writes
--- one file per build, named from `PROPERTY` on the outermost build, and never
--- reads `gradle.parent.rootProject`, which an included build's `whenReady`
--- can reach before it exists. Each build's `help` depends on its included
--- builds' `help`, because an included build no scheduled task needs is
--- configured and never reaches `whenReady`. Measured on 7.6.4, 8.13, 9.3.1
--- and 9.6.0, D-146.
local SCRIPT = [==[
import groovy.json.JsonOutput

def DENY = ['class', 'convention', 'conventionMapping', 'extensions', 'asDynamicObject', 'project', 'metaClass',
            'properties', 'services', 'objects', 'providers', 'fileOperations', 'layout', 'asMap', 'rootProject',
            'parent', 'gradle', 'buildscript', 'configurations', 'dependencies', 'artifacts', 'components', 'tasks',
            'plugins', 'pluginManager', 'conventionWhileDisabledDeprecationLogger', 'taskThatOwnsThisObject',
            'modelIdentityDisplayName', 'publishableArtifacts', 'attributes', 'factoryId', 'xmlAction', 'ant', 'logger',
            'logging', 'state', 'modelRegistry', 'inheritedScope', 'identityPath', 'projectEvaluator', 'instantiator',
            'dependencyFactory', 'immutable'] as Set
def WALK_DEPTH = 5
def WALK_BUDGET = 2000
def LIVE_TYPES = [org.gradle.api.Project, org.gradle.api.Task, org.gradle.api.invocation.Gradle,
                  org.gradle.api.initialization.Settings, org.gradle.api.model.ObjectFactory,
                  org.gradle.api.provider.ProviderFactory]

def unrendered = { String why -> ['$unrendered': why] }

def slashes = { String path -> path.replace('\\', '/') }

def pathFrom = { File base, Object target ->
  if (target == null) return null
  def file = target instanceof File ? target : new File(target.toString())
  def from = base.toPath().toAbsolutePath().normalize()
  def to = file.toPath().toAbsolutePath().normalize()
  if (!to.startsWith(from)) return slashes(to.toString())
  def relative = slashes(from.relativize(to).toString())
  relative.isEmpty() ? '.' : relative
}

def unwrap = { value ->
  if (value instanceof org.gradle.api.provider.Provider) return value.getOrNull()
  value
}

def scalar = { value ->
  value instanceof CharSequence || value instanceof Number || value instanceof Boolean || value instanceof Enum
}

def sourceDirectories = { File base, org.gradle.api.file.SourceDirectorySet set ->
  [srcDirs: set.srcDirs.collect { pathFrom(base, it) }, includes: set.includes as List, excludes: set.excludes as List]
}

def plain
plain = { File base, Object raw ->
  def value = unwrap(raw)
  if (value == null) return null
  if (value instanceof Boolean || value instanceof Number) return value
  if (scalar(value)) return value.toString()
  if (value instanceof org.gradle.jvm.toolchain.JavaLanguageVersion) return value.asInt().toString()
  if (value instanceof File) return pathFrom(base, value)
  if (value instanceof org.gradle.api.file.FileSystemLocation) return pathFrom(base, value.asFile)
  if (value instanceof org.gradle.api.file.SourceDirectorySet) return sourceDirectories(base, value)
  if (value instanceof org.gradle.api.file.FileCollection) return unrendered('file collection')
  if (value instanceof Map) return value.collectEntries { key, item -> [key.toString(), plain(base, item)] }
  if (value instanceof Iterable) return value.collect { plain(base, it) }.findAll { it != null }
  value.toString()
}

def safely = { Closure read ->
  try { read() } catch (Throwable failure) { unrendered('unreadable: ' + failure.class.simpleName) }
}

class WalkBudget { int remaining }

def walk
walk = { File base, Object raw, int depth, Set seen, WalkBudget budget ->
  def value
  try { value = unwrap(raw) } catch (Throwable failure) { return unrendered('unreadable: ' + failure.class.simpleName) }
  if (value == null) return null
  if (scalar(value) || value instanceof org.gradle.jvm.toolchain.JavaLanguageVersion || value instanceof File
      || value instanceof org.gradle.api.file.FileSystemLocation || value instanceof org.gradle.api.file.FileCollection) {
    return plain(base, value)
  }
  if (LIVE_TYPES.any { it.isInstance(value) }) return unrendered('live object ' + value.getClass().name)
  if (budget.remaining <= 0) return unrendered('budget')
  budget.remaining--
  def identity = System.identityHashCode(value)
  if (depth > WALK_DEPTH) return unrendered('depth')
  if (seen.contains(identity)) return unrendered('cycle')
  seen << identity
  try {
    if (value instanceof org.gradle.api.NamedDomainObjectCollection) {
      return value.names.collectEntries { name -> [name, safely { walk(base, value.getByName(name), depth + 1, seen, budget) }] }
    }
    if (value instanceof Map) return value.collectEntries { key, item -> [key.toString(), walk(base, item, depth + 1, seen, budget)] }
    if (value instanceof Iterable) return value.collect { walk(base, it, depth + 1, seen, budget) }.findAll { it != null }
    if (value.getClass().name.startsWith('java.')) return value.toString()
    def out = [:]
    value.metaClass.properties.each { property ->
      def name = property.name
      if (DENY.contains(name) || name.startsWith('_gr_') || name.startsWith('__')) return
      try { out[name] = walk(base, property.getProperty(value), depth + 1, seen, budget) } catch (Throwable ignored) { }
    }
    out.isEmpty() ? value.toString() : out
  } finally {
    seen.remove(identity)
  }
}

def typeOf = { Object instance ->
  def type = instance.getClass()
  if (!type.name.endsWith('_Decorated')) return type
  type.superclass != Object ? type.superclass : (type.interfaces.find { !it.name.startsWith('groovy.') && !it.name.startsWith('org.gradle.api.internal.') } ?: type)
}

def isCoreType = { Class type -> type.name.startsWith('org.gradle.') }

def scriptOf = { File base, Class type ->
  def loader = String.valueOf(type?.classLoader)
  def groovy = loader =~ /groovy-script-(.+)-loader\)/
  if (groovy.find()) return pathFrom(base, groovy.group(1))
  def kotlin = loader =~ /kotlin-dsl:(.+?\.kts):/
  if (kotlin.find()) return pathFrom(base, kotlin.group(1))
  null
}

def pluginIdsByLocation = [:]
def pluginIdsIn = { File location ->
  def found = [:]
  def remember = { String entryName, InputStream stream ->
    def properties = new Properties()
    properties.load(stream)
    def implementation = properties.getProperty('implementation-class')
    if (implementation == null) return
    def id = entryName.substring(entryName.lastIndexOf('/') + 1) - ~/\.properties$/
    found.get(implementation.trim(), []) << id
  }
  if (location.isFile()) {
    def zip = new java.util.zip.ZipFile(location)
    try {
      zip.entries().findAll { !it.directory && it.name ==~ /META-INF\/gradle-plugins\/[^\/]+\.properties/ }.each { entry ->
        zip.getInputStream(entry).withCloseable { remember(entry.name, it) }
      }
    } finally { zip.close() }
  } else if (location.isDirectory()) {
    new File(location, 'META-INF/gradle-plugins').listFiles()?.findAll { it.name.endsWith('.properties') }?.each { file ->
      file.withInputStream { remember('META-INF/gradle-plugins/' + file.name, it) }
    }
  }
  found
}
def pluginIdsOf = { Class type ->
  def location = null
  try { location = type.protectionDomain?.codeSource?.location } catch (Throwable ignored) { }
  if (location == null || location.protocol != 'file') return []
  def file = new File(location.toURI())
  if (!pluginIdsByLocation.containsKey(file.path)) {
    pluginIdsByLocation[file.path] = safely { pluginIdsIn(file) }
  }
  def ids = pluginIdsByLocation[file.path]
  ids instanceof Map && ids.containsKey('$unrendered') == false ? (ids[type.name] ?: []).sort() : []
}

def pluginsOf = { File base, Iterable plugins ->
  plugins.collect { plugin ->
    def type = typeOf(plugin)
    def ids = []
    for (def candidate = type; candidate != null && candidate != Object && ids.isEmpty(); candidate = candidate.superclass) {
      ids = pluginIdsOf(candidate)
      if (!ids.isEmpty()) type = candidate
    }
    [type: type.name, ids: ids, core: isCoreType(type), script: scriptOf(base, type)]
  }
}

def repositoriesOf = { Iterable repositories ->
  repositories.collect { repository ->
    def kind = 'other'
    if (repository instanceof org.gradle.api.artifacts.repositories.MavenArtifactRepository) kind = 'maven'
    else if (repository instanceof org.gradle.api.artifacts.repositories.IvyArtifactRepository) kind = 'ivy'
    else if (repository instanceof org.gradle.api.artifacts.repositories.FlatDirectoryArtifactRepository) kind = 'flatDir'
    def url = null
    if (kind == 'maven' || kind == 'ivy') url = repository.url?.toString()
    [name: repository.name, kind: kind, type: typeOf(repository).name, url: url]
  }
}

def digests = [:]
def sha256 = { File file ->
  digests.computeIfAbsent(file.path) {
    def digest = java.security.MessageDigest.getInstance('SHA-256')
    file.eachByte(65536) { byte[] buffer, int length -> digest.update(buffer, 0, length) }
    digest.digest().encodeHex().toString()
  }
}

def repositoryOf = { component ->
  try { return component.repositoryId } catch (Throwable ignored) { }
  try { return component.repositoryName } catch (Throwable ignored) { return null }
}

def identifierKind = { identifier ->
  if (identifier instanceof org.gradle.api.artifacts.component.ModuleComponentIdentifier) return 'module'
  if (identifier instanceof org.gradle.api.artifacts.component.ProjectComponentIdentifier) return 'project'
  identifier.getClass().simpleName
}

def resolvedRows = { configuration ->
  def repositories = [:]
  configuration.incoming.resolutionResult.allComponents.each { component ->
    repositories[component.id.displayName] = repositoryOf(component)
  }
  configuration.incoming.artifacts.artifacts.collect { artifact ->
    def identifier = artifact.id.componentIdentifier
    def file = artifact.file
    def row = [configuration: configuration.name, component: identifier.displayName, kind: identifierKind(identifier),
               fileName: (artifact.id.hasProperty('fileName') ? artifact.id.fileName : file.name),
               sha256: (file.isFile() ? sha256(file) : null), repository: repositories[identifier.displayName]]
    if (identifier instanceof org.gradle.api.artifacts.component.ModuleComponentIdentifier) {
      row.group = identifier.group
      row.module = identifier.module
      row.version = identifier.version
    }
    if (identifier instanceof org.gradle.api.artifacts.component.ProjectComponentIdentifier) row.project = identifier.projectPath
    row
  }
}

def resolveInto = { configuration, List resolved, List errors ->
  if (configuration == null || !configuration.canBeResolved) return
  try { resolved.addAll(resolvedRows(configuration)) }
  catch (Throwable failure) { errors << [configuration: configuration.name, error: failure.toString()] }
}

def declaredRows = { configurations ->
  configurations.collectMany { configuration ->
    configuration.dependencies.collect { dependency ->
      def row = [configuration: configuration.name, type: typeOf(dependency).name]
      if (dependency instanceof org.gradle.api.artifacts.ProjectDependency) {
        row.kind = 'project'
        row.project = dependency.hasProperty('path') ? dependency.path : dependency.dependencyProject.path
      } else if (dependency instanceof org.gradle.api.artifacts.ExternalModuleDependency) {
        row.kind = 'module'
        row.group = dependency.group
        row.name = dependency.name
        row.version = dependency.version
      } else if (dependency instanceof org.gradle.api.artifacts.FileCollectionDependency) {
        row.kind = 'files'
      } else {
        row.kind = 'other'
        row.name = dependency.name
      }
      row
    }
  }
}

def resolvedConfigurationNames = { project ->
  def names = [] as LinkedHashSet
  def sourceSets = project.extensions.findByName('sourceSets')
  sourceSets?.each { set ->
    names << set.compileClasspathConfigurationName
    names << set.runtimeClasspathConfigurationName
    names << set.annotationProcessorConfigurationName
  }
  names
}

def dependenciesOf = { project ->
  def resolved = []
  def errors = []
  resolvedConfigurationNames(project).each { name -> resolveInto(project.configurations.findByName(name), resolved, errors) }
  [declared: declaredRows(project.configurations), resolved: resolved, errors: errors]
}

def buildscriptOf = { project ->
  def resolved = []
  def errors = []
  resolveInto(project.buildscript.configurations.findByName('classpath'), resolved, errors)
  [repositories: repositoriesOf(project.buildscript.repositories), resolved: resolved, errors: errors]
}

def javaExtension = { File base, extension ->
  [toolchain: [languageVersion: safely { plain(base, extension.toolchain.languageVersion) },
               vendor: safely { plain(base, extension.toolchain.vendor) }],
   sourceCompatibility: safely { plain(base, extension.sourceCompatibility) },
   targetCompatibility: safely { plain(base, extension.targetCompatibility) }]
}

def sourceSetsExtension = { File base, extension ->
  extension.collectEntries { set ->
    def others = [:]
    set.extensions.extensionsSchema.elements.each { element ->
      def value = set.extensions.findByName(element.name)
      if (value instanceof org.gradle.api.file.SourceDirectorySet) others[element.name] = sourceDirectories(base, value)
    }
    [set.name, [java: sourceDirectories(base, set.java), resources: sourceDirectories(base, set.resources), others: others,
                compileClasspath: set.compileClasspathConfigurationName, runtimeClasspath: set.runtimeClasspathConfigurationName,
                annotationProcessor: set.annotationProcessorConfigurationName, implementation: set.implementationConfigurationName,
                compileOnly: set.compileOnlyConfigurationName, runtimeOnly: set.runtimeOnlyConfigurationName,
                compileJavaTask: set.compileJavaTaskName, classesTask: set.classesTaskName]]
  }
}

def applicationExtension = { File base, extension ->
  [mainClass: safely { plain(base, extension.mainClass) }, applicationName: safely { plain(base, extension.applicationName) },
   applicationDefaultJvmArgs: safely { plain(base, extension.applicationDefaultJvmArgs) }]
}

def CORE_EXTENSION_READERS = [java: javaExtension, sourceSets: sourceSetsExtension, application: applicationExtension]

def extensionsOf = { File base, container ->
  container.extensionsSchema.elements.findAll { it.name != 'ext' }.collectEntries { element ->
    def extension = container.findByName(element.name)
    def type = element.publicType.concreteClass
    def entry = [type: type.name, core: isCoreType(type)]
    if (extension == null) return [element.name, entry]
    def reader = CORE_EXTENSION_READERS[element.name]
    if (entry.core && reader != null) entry.value = safely { reader(base, extension) }
    if (!entry.core) entry.value = safely { walk(base, extension, 0, [] as Set, new WalkBudget(remaining: WALK_BUDGET)) }
    [element.name, entry]
  }
}

def jarReader = { File base, task ->
  [archiveFileName: safely { plain(base, task.archiveFileName) }, archiveBaseName: safely { plain(base, task.archiveBaseName) },
   archiveAppendix: safely { plain(base, task.archiveAppendix) }, archiveVersion: safely { plain(base, task.archiveVersion) },
   archiveClassifier: safely { plain(base, task.archiveClassifier) }, archiveExtension: safely { plain(base, task.archiveExtension) },
   destinationDirectory: safely { plain(base, task.destinationDirectory) },
   manifestAttributes: safely { plain(base, task.manifest.attributes) },
   preserveFileTimestamps: safely { plain(base, task.preserveFileTimestamps) },
   reproducibleFileOrder: safely { plain(base, task.reproducibleFileOrder) },
   duplicatesStrategy: safely { plain(base, task.duplicatesStrategy) }]
}

def javaCompileReader = { File base, task ->
  def encoding = task.options.encoding
  [encoding: encoding, encodingSet: encoding != null, release: safely { plain(base, task.options.release) },
   sourceCompatibility: safely { plain(base, task.sourceCompatibility) },
   targetCompatibility: safely { plain(base, task.targetCompatibility) },
   compilerArgs: safely { plain(base, task.options.compilerArgs) },
   destinationDirectory: safely { plain(base, task.destinationDirectory) }]
}

def testReader = { File base, task ->
  [framework: safely { typeOf(task.options).name }, includes: safely { plain(base, task.includes) },
   excludes: safely { plain(base, task.excludes) }, filterIncludes: safely { plain(base, task.filter.includePatterns) },
   jvmArgs: safely { plain(base, task.jvmArgs) }, systemProperties: safely { plain(base, task.systemProperties) },
   maxParallelForks: safely { plain(base, task.maxParallelForks) }, forkEvery: safely { plain(base, task.forkEvery) }]
}

def javadocReader = { File base, task ->
  [title: safely { plain(base, task.title) }, encoding: safely { plain(base, task.options.encoding) },
   failOnError: safely { plain(base, task.failOnError) }, destinationDir: safely { plain(base, task.destinationDir) }]
}

def javaExecReader = { File base, task ->
  [mainClass: safely { plain(base, task.mainClass) }, args: safely { plain(base, task.args) },
   jvmArgs: safely { plain(base, task.jvmArgs) }, workingDir: safely { plain(base, task.workingDir) }]
}

def TASK_READERS = [[org.gradle.api.tasks.bundling.Jar, 'jar', jarReader],
                    [org.gradle.api.tasks.compile.JavaCompile, 'javaCompile', javaCompileReader],
                    [org.gradle.api.tasks.testing.Test, 'test', testReader],
                    [org.gradle.api.tasks.javadoc.Javadoc, 'javadoc', javadocReader],
                    [org.gradle.api.tasks.JavaExec, 'javaExec', javaExecReader]]

def actionsOf = { File base, task ->
  task.actions.collect { action ->
    def inner = action
    try { inner = action.action } catch (Throwable ignored) { }
    def closure = null
    try { closure = inner.closure } catch (Throwable ignored) { }
    def type = closure != null ? closure.getClass() : inner.getClass()
    [type: type.name, script: scriptOf(base, type)]
  }
}

def tasksOf = { File base, project ->
  project.tasks.collect { task ->
    def type = typeOf(task)
    def actions = actionsOf(base, task)
    def typeScript = scriptOf(base, type)
    def scripts = ([typeScript] + actions*.script).findAll { it != null }.unique()
    def entry = [name: task.name, path: task.path, type: type.name, enabled: task.enabled, actions: actions,
                 buildLogic: !scripts.isEmpty(), scripts: scripts]
    def reader = TASK_READERS.find { it[0].isInstance(task) }
    if (reader != null) {
      entry.reader = reader[1]
      entry.values = safely { reader[2](base, task) }
    }
    entry
  }
}

def projectOf = { File base, project ->
  [path: project.path, name: project.name, dir: pathFrom(base, project.projectDir),
   buildFile: (project.buildFile.isFile() ? pathFrom(base, project.buildFile) : null),
   version: project.version.toString(), group: project.group.toString(),
   parent: project.parent?.path, children: project.childProjects.values().collect { it.path },
   plugins: pluginsOf(base, project.plugins), extensions: extensionsOf(base, project.extensions),
   repositories: repositoriesOf(project.repositories), buildscript: buildscriptOf(project),
   dependencies: dependenciesOf(project), tasks: tasksOf(base, project)]
}

def settingsFacts = [:]
gradle.settingsEvaluated { settings ->
  def base = settings.rootDir
  settingsFacts.pluginManagementRepositories = repositoriesOf(settings.pluginManagement.repositories)
  settingsFacts.settingsPlugins = pluginsOf(base, settings.plugins)
  settingsFacts.settingsExtensions = extensionsOf(base, settings.extensions)
}

def outputFor = { invocation ->
  def outermost = invocation
  while (outermost.parent != null) outermost = outermost.parent
  def requested = outermost.startParameter.systemPropertiesArgs['daukle.migrate.model'] ?: System.getProperty('daukle.migrate.model')
  if (requested == null) throw new GradleException('daukle.migrate.model names no file to write the model to')
  def file = new File(requested)
  if (!file.isAbsolute()) file = new File(outermost.startParameter.currentDir, requested)
  if (invocation.parent == null) return file
  def identity = invocation.hasProperty('identityPath') ? invocation.identityPath.toString() : ':' + invocation.rootProject.name
  def suffix = identity.replaceAll(/^:/, '').replace(':', '-')
  new File(file.parentFile, (file.name - ~/\.json$/) + '-' + suffix + '.json')
}

gradle.projectsEvaluated {
  def help = gradle.rootProject.tasks.findByName('help')
  if (help != null) gradle.includedBuilds.each { build -> help.dependsOn(build.task(':help')) }
}

gradle.taskGraph.whenReady {
  def base = gradle.rootProject.rootDir
  def model = [schema: 1, gradleVersion: gradle.gradleVersion, rootDir: slashes(base.path),
               included: gradle.parent != null,
               identityPath: (gradle.hasProperty('identityPath') ? gradle.identityPath.toString() : null),
               jvm: [fileEncoding: System.getProperty('file.encoding'), nativeEncoding: System.getProperty('native.encoding'),
                     defaultCharset: java.nio.charset.Charset.defaultCharset().name(),
                     javaVersion: System.getProperty('java.version')],
               includedBuilds: gradle.includedBuilds.collect { [name: it.name, dir: pathFrom(base, it.projectDir)] },
               pluginManagementRepositories: settingsFacts.pluginManagementRepositories ?: [],
               settingsPlugins: settingsFacts.settingsPlugins ?: [],
               settingsExtensions: settingsFacts.settingsExtensions ?: [:],
               projects: gradle.rootProject.allprojects.collect { projectOf(base, it) }]
  def file = outputFor(gradle)
  file.parentFile.mkdirs()
  file.setText(JsonOutput.prettyPrint(JsonOutput.toJson(model)), 'UTF-8')
}
]==]

return { SCRIPT = SCRIPT, PROPERTY = "daukle.migrate.model" }
