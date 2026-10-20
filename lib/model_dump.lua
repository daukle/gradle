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
local PROPERTY = "daukle.migrate.model"

--- The configuration name the dump gives the launcher rows it resolves itself.
local IMPLIED_LAUNCHER = "daukleImpliedLauncher"

local SCRIPT = [==[
import groovy.json.JsonOutput

def MODEL_PROPERTY = ']==] .. PROPERTY .. [==['
def IMPLIED_LAUNCHER = ']==] .. IMPLIED_LAUNCHER .. [==['

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

/**
 * Whether a build script could have assigned the property: a setter, a non-final field, or a lazy
 * Gradle type, which the Groovy DSL assigns through its own setter.
 */
def isAssignable = { MetaProperty property, Object raw ->
  if (raw instanceof org.gradle.api.provider.HasConfigurableValue) return true
  if (property instanceof MetaBeanProperty) return property.setter != null
  !java.lang.reflect.Modifier.isFinal(property.modifiers)
}

/**
 * The bounded walk of a third-party extension. A list, a map and a file arrive as one-key tables
 * (`$list`, `$map`, `$file`), because JSON cannot tell an empty list from an object nor a path
 * from a string, and an object names the properties no script can assign in `$readOnly`.
 * It sees only what an object exposes as a public property (a getter or a public field), so state
 * a plugin keeps elsewhere is invisible to it; a getter that throws is an `unrendered` value.
 */
def walk
walk = { File base, Object raw, int depth, Set seen, WalkBudget budget ->
  def value
  try { value = unwrap(raw) } catch (Throwable failure) { return unrendered('unreadable: ' + failure.class.simpleName) }
  if (value == null) return null
  if (value instanceof File) return ['$file': pathFrom(base, value)]
  if (value instanceof org.gradle.api.file.FileSystemLocation) return ['$file': pathFrom(base, value.asFile)]
  if (scalar(value) || value instanceof org.gradle.jvm.toolchain.JavaLanguageVersion
      || value instanceof org.gradle.api.file.FileCollection) {
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
    if (value instanceof Map) return ['$map': value.collectEntries { key, item -> [key.toString(), walk(base, item, depth + 1, seen, budget)] }]
    if (value instanceof Iterable) return ['$list': value.collect { walk(base, it, depth + 1, seen, budget) }.findAll { it != null }]
    if (value.getClass().name.startsWith('java.')) return value.toString()
    def out = [:]
    def readOnly = []
    value.metaClass.properties.each { property ->
      def name = property.name
      if (DENY.contains(name) || name.startsWith('_gr_') || name.startsWith('__')) return
      try {
        def item = property.getProperty(value)
        out[name] = walk(base, item, depth + 1, seen, budget)
        if (!isAssignable(property, item)) readOnly << name
      } catch (Throwable failure) {
        out[name] = unrendered('unreadable: ' + failure.class.simpleName)
      }
    }
    if (out.isEmpty()) return value.toString()
    if (!readOnly.isEmpty()) out['$readOnly'] = readOnly.sort()
    out
  } finally {
    seen.remove(identity)
  }
}

def typeOf = { Object instance ->
  def type = instance.getClass()
  if (!type.name.endsWith('_Decorated')) return type
  type.superclass != Object ? type.superclass : (type.interfaces.find { !it.name.startsWith('groovy.') && !it.name.startsWith('org.gradle.api.internal.') } ?: type)
}

def locationOf = { Class type ->
  def location = null
  try { location = type.protectionDomain?.codeSource?.location } catch (Throwable ignored) { }
  if (location == null || location.protocol != 'file') return null
  new File(location.toURI())
}

def GRADLE_HOME = gradle.gradleHomeDir?.canonicalFile?.toPath()

/**
 * Whether a class is Gradle's own: an `org.gradle.` name loaded from the Gradle distribution. The
 * name alone is not enough, because a third-party plugin can live under `org.gradle.` too (the
 * foojay resolver does), and the location alone is not either, because Groovy and Kotlin ship there.
 */
def isCoreType = { Class type ->
  if (!type.name.startsWith('org.gradle.')) return false
  def location = locationOf(type)
  location == null || GRADLE_HOME == null || location.canonicalFile.toPath().startsWith(GRADLE_HOME)
}

/**
 * A class name a script compiles to: a Groovy script's closure (build_<hash>$_run_closure1) or a
 * Kotlin script's nested class or lambda (Build_gradle$1). A second signal beside the class loader,
 * whose display name is Gradle-internal, so that a renamed loader degrades detection to the
 * closures and lambdas rather than to nothing; it misses a Groovy script's top-level class.
 */
def namedLikeScriptClass = { Class type ->
  def name = type?.name ?: ''
  name ==~ /[A-Za-z0-9_]+_[a-z0-9]{20,}[$].*/ || name ==~ /[A-Z][A-Za-z0-9_]*_gradle[$].*/
}

def UNKNOWN_SCRIPT = '<unknown script>'

def scriptOf = { File base, Class type ->
  def loader = String.valueOf(type?.classLoader)
  def groovy = loader =~ /groovy-script-(.+)-loader\)/
  if (groovy.find()) return pathFrom(base, groovy.group(1))
  def kotlin = loader =~ /kotlin-dsl:(.+?\.kts):/
  if (kotlin.find()) return pathFrom(base, kotlin.group(1))
  namedLikeScriptClass(type) ? UNKNOWN_SCRIPT : null
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
  def file = locationOf(type)
  if (file == null) return []
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
    def location = locationOf(type)
    [type: type.name, ids: ids, core: isCoreType(type), script: scriptOf(base, type),
     jar: (location != null && location.isFile() ? location.name : null)]
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

/**
 * The build a project component belongs to, as an identity path (`:` for the build being dumped).
 * @implNote `BuildIdentifier.buildPath` exists from 8.2 and `name` is gone in 9; on 7.6.4 `name` is
 * `:` for the current build and the bare build name for an included one. Measured on 7.6.4 and 9.6.0.
 */
def buildOf = { identifier ->
  try { return identifier.build.buildPath } catch (Throwable ignored) { }
  def name = identifier.build.name
  name == ':' ? ':' : ':' + name
}

def isProjectComponent = { identifier -> identifier instanceof org.gradle.api.artifacts.component.ProjectComponentIdentifier }

/**
 * How one declared edge of the resolution root is named in `via`: by the project it selected, else by the
 * module it requested, so a module coordinate an included build substitutes reads as that project.
 */
def edgeKey = { dependency ->
  def selected = dependency.selected.id
  if (isProjectComponent(selected)) return 'project ' + buildOf(selected) + ' ' + selected.projectPath
  def requested = dependency.requested
  if (requested instanceof org.gradle.api.artifacts.component.ModuleComponentSelector) {
    return 'module ' + requested.group + ':' + requested.module
  }
  'other ' + requested.displayName
}

def isFollowed = { dependency ->
  dependency instanceof org.gradle.api.artifacts.result.ResolvedDependencyResult && !dependency.constraint
}

/**
 * For each component a configuration resolves, the declared edges of its root it is reachable through,
 * which is what tells a transitive of an `api` declaration from one of an `implementation` declaration,
 * and a row a required project brings from one the project declares itself.
 */
def viaOf = { configuration ->
  def via = [:]
  configuration.incoming.resolutionResult.root.dependencies.findAll { isFollowed(it) }.each { edge ->
    def key = edgeKey(edge)
    def seen = [] as Set
    def pending = [edge.selected]
    while (!pending.isEmpty()) {
      def component = pending.remove(pending.size() - 1)
      if (!seen.add(component.id.displayName)) continue
      via.get(component.id.displayName, [] as TreeSet) << key
      component.dependencies.findAll { isFollowed(it) }.each { pending << it.selected }
    }
  }
  via
}

def classNamesByFile = [:]
def classNamesOf = { File file ->
  classNamesByFile.computeIfAbsent(file.path) {
    def names = [] as Set
    if (!file.isFile() || !file.name.endsWith('.jar')) return names
    try {
      def zip = new java.util.zip.ZipFile(file)
      try {
        zip.entries().each { entry ->
          def name = entry.name
          if (!entry.directory && name.endsWith('.class') && !name.startsWith('META-INF/') && !name.endsWith('module-info.class')) names << name
        }
      } finally { zip.close() }
    } catch (Throwable ignored) { }
    names
  }
}

/**
 * Names on each row the sha256 of every earlier row of the same configuration holding a class of the same
 * name, which is where the order of a classpath decides what is loaded.
 * @implNote only jars are read: a project's classes directory does not exist before the build runs.
 */
def markOverlaps = { List rows, List files ->
  def owner = [:]
  rows.eachWithIndex { row, index ->
    def overlaps = [] as LinkedHashSet
    classNamesOf(files[index]).each { name ->
      def earlier = owner.putIfAbsent(name, index)
      if (earlier != null && earlier != index && rows[earlier].sha256 != null) overlaps << rows[earlier].sha256
    }
    row.overlaps = overlaps as List
  }
  rows
}

def resolvedRows = { configuration ->
  def repositories = [:]
  configuration.incoming.resolutionResult.allComponents.each { component ->
    repositories[component.id.displayName] = repositoryOf(component)
  }
  def via = viaOf(configuration)
  def artifacts = configuration.incoming.artifacts.artifacts as List
  markOverlaps(artifacts.collect { artifact ->
    def identifier = artifact.id.componentIdentifier
    def file = artifact.file
    def row = [configuration: configuration.name, component: identifier.displayName, kind: identifierKind(identifier),
               fileName: (artifact.id.hasProperty('fileName') ? artifact.id.fileName : file.name),
               sha256: (file.isFile() ? sha256(file) : null), repository: repositories[identifier.displayName],
               via: (via[identifier.displayName] ?: []) as List]
    if (identifier instanceof org.gradle.api.artifacts.component.ModuleComponentIdentifier) {
      row.group = identifier.group
      row.module = identifier.module
      row.version = identifier.version
    }
    if (isProjectComponent(identifier)) {
      row.project = identifier.projectPath
      row.build = buildOf(identifier)
    }
    row
  }, artifacts.collect { it.file })
}

def resolveInto = { configuration, List resolved, List errors ->
  if (configuration == null || !configuration.canBeResolved) return
  try { resolved.addAll(resolvedRows(configuration)) }
  catch (Throwable failure) { errors << [configuration: configuration.name, error: failure.toString()] }
}

/**
 * @implNote a `ProjectDependency` has `path` on 9.6.0 and no `dependencyProject`; on 7.6.4 it has no
 * `path` and `dependencyProject.path` is the project's path. Measured on both, D-146.
 */
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

def isPlatformModule = { row, String module -> row.group == 'org.junit.platform' && row.module == module }

/**
 * The JUnit Platform launcher Gradle 8 hands a test run without resolving it, resolved from the
 * project's own repositories at the engine's version, so it can be pinned like any other row.
 * Not transitive: everything it needs is on the test runtime classpath beside the engine.
 */
def impliedLauncherInto = { project, List resolved, List errors ->
  def test = project.extensions.findByName('sourceSets')?.findByName('test')
  if (test == null) return
  def runtime = resolved.findAll { it.configuration == test.runtimeClasspathConfigurationName }
  def engine = runtime.find { isPlatformModule(it, 'junit-platform-engine') }
  if (engine == null || runtime.any { isPlatformModule(it, 'junit-platform-launcher') }) return
  def launcher = project.configurations.detachedConfiguration(
      project.dependencies.create("org.junit.platform:junit-platform-launcher:${engine.version}"))
  launcher.transitive = false
  try { resolved.addAll(resolvedRows(launcher).collect { row -> row.configuration = IMPLIED_LAUNCHER; row }) }
  catch (Throwable failure) { errors << [configuration: IMPLIED_LAUNCHER, error: failure.toString()] }
}

def dependenciesOf = { project ->
  def resolved = []
  def errors = []
  resolvedConfigurationNames(project).each { name -> resolveInto(project.configurations.findByName(name), resolved, errors) }
  impliedLauncherInto(project, resolved, errors)
  [declared: declaredRows(project.configurations), resolved: resolved, errors: errors]
}

def buildscriptOf = { owner ->
  def resolved = []
  def errors = []
  resolveInto(owner.buildscript.configurations.findByName('classpath'), resolved, errors)
  [repositories: repositoriesOf(owner.buildscript.repositories), resolved: resolved, errors: errors]
}

/**
 * @implNote `rawSourceCompatibility` and `rawTargetCompatibility` are internal to
 * `DefaultJavaPluginExtension` and null when the build set nothing, where the evaluated value is the
 * toolchain's or the dump daemon's JDK. Measured on 7.6.4, 8.13 and 9.6.0.
 */
def javaExtension = { File base, extension, owner ->
  [toolchain: [languageVersion: safely { plain(base, extension.toolchain.languageVersion) },
               vendor: safely { plain(base, extension.toolchain.vendor) }],
   sourceCompatibility: safely { plain(base, extension.sourceCompatibility) },
   targetCompatibility: safely { plain(base, extension.targetCompatibility) },
   rawSourceCompatibility: safely { plain(base, extension.rawSourceCompatibility) },
   rawTargetCompatibility: safely { plain(base, extension.rawTargetCompatibility) }]
}

/**
 * The files a source set's classpath holds beyond its configuration's own, such as another set's
 * output added with `compileClasspath += ...`, which no resolved artifact row can show.
 */
def filesBeyondConfiguration = { File base, owner, org.gradle.api.file.FileCollection classpath, String configurationName ->
  def configuration = owner.configurations.findByName(configurationName)
  def own = configuration != null && configuration.canBeResolved ? configuration.files : [] as Set
  (classpath.files - own).collect { pathFrom(base, it) }.sort()
}

def sourceSetsExtension = { File base, extension, owner ->
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
                compileJavaTask: set.compileJavaTaskName, classesTask: set.classesTaskName,
                output: safely { set.output.files.collect { pathFrom(base, it) }.sort() },
                compileClasspathBeyond: safely { filesBeyondConfiguration(base, owner, set.compileClasspath, set.compileClasspathConfigurationName) },
                runtimeClasspathBeyond: safely { filesBeyondConfiguration(base, owner, set.runtimeClasspath, set.runtimeClasspathConfigurationName) }]]
  }
}

def applicationExtension = { File base, extension, owner ->
  [mainClass: safely { plain(base, extension.mainClass) }, applicationName: safely { plain(base, extension.applicationName) },
   applicationDefaultJvmArgs: safely { plain(base, extension.applicationDefaultJvmArgs) }]
}

def gradlePluginExtension = { File base, extension, owner ->
  [plugins: extension.plugins.collectEntries { plugin ->
    [plugin.name, [id: safely { plain(base, plugin.id) }, implementationClass: safely { plain(base, plugin.implementationClass) },
                   displayName: safely { plain(base, plugin.displayName) }, description: safely { plain(base, plugin.description) }]]
  }]
}

def CORE_EXTENSION_READERS = [java: javaExtension, sourceSets: sourceSetsExtension, application: applicationExtension,
                              gradlePlugin: gradlePluginExtension]

/**
 * The type that decides whether an extension is the build's or Gradle's: for a container (a
 * `project.container(Thing)` or `objects.domainObjectContainer(Thing)`), whose own type is always
 * Gradle's, the type of what it holds, read from the declared type argument, else the container's
 * element type, else its first element.
 */
def deciding = { element, extension ->
  def type = element.publicType.concreteClass
  if (!(extension instanceof org.gradle.api.NamedDomainObjectCollection)) return type
  def held = null
  try {
    def arguments = element.publicType.parameterized ? element.publicType.actualTypeArguments : []
    if (!arguments.isEmpty()) held = arguments[0].concreteClass
  } catch (Throwable ignored) { }
  if (held == null || held == Object) {
    try { held = extension.type } catch (Throwable ignored) { }
  }
  if ((held == null || held == Object) && !extension.isEmpty()) held = typeOf(extension.iterator().next())
  held ?: type
}

def extensionsOf = { File base, owner ->
  def container = owner.extensions
  container.extensionsSchema.elements.findAll { it.name != 'ext' }.collectEntries { element ->
    def extension = container.findByName(element.name)
    def type = element.publicType.concreteClass
    def entry = [type: type.name, core: isCoreType(extension == null ? type : deciding(element, extension))]
    if (extension == null) return [element.name, entry]
    def reader = CORE_EXTENSION_READERS[element.name]
    if (entry.core && reader != null) entry.value = safely { reader(base, extension, owner) }
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
   plugins: pluginsOf(base, project.plugins), extensions: extensionsOf(base, project),
   repositories: repositoriesOf(project.repositories), buildscript: buildscriptOf(project),
   dependencies: dependenciesOf(project), tasks: tasksOf(base, project)]
}

def repositoriesByName = { Iterable repositories ->
  repositoriesOf(repositories).collectEntries { [it.name, [kind: it.kind, type: it.type, url: it.url]] }
}

/** @implNote `toolchainManagement` is a property of `Settings`, not one of its extensions. */
def toolchainRepositoriesOf = { settings ->
  def jvm = settings.toolchainManagement.extensions.findByName('jvm')
  if (jvm == null) return [:]
  jvm.javaRepositories.asList.collectEntries { [it.name, [resolverClass: plain(settings.rootDir, it.resolverClass.getOrNull()?.name)]] }
}

def buildCacheOf = { File base, cache ->
  if (cache == null) return null
  [type: typeOf(cache).name, enabled: cache.enabled, push: cache.push,
   url: (cache.hasProperty('url') ? cache.url?.toString() : null),
   directory: (cache.hasProperty('directory') && cache.directory != null ? pathFrom(base, cache.directory) : null)]
}

/**
 * The settings blocks Gradle itself provides, read by type, so the migrator can compare them with the
 * generated build's: the walk is for third-party extensions only, and these are where a hand-written
 * settings file most often says something no key carries.
 */
def settingsCoreOf = { settings ->
  def base = settings.rootDir
  [toolchainManagement: safely { [javaRepositories: toolchainRepositoriesOf(settings)] },
   buildCache: safely { [local: buildCacheOf(base, settings.buildCache.local), remote: buildCacheOf(base, settings.buildCache.remote)] },
   dependencyResolutionManagement: safely {
     [repositories: repositoriesByName(settings.dependencyResolutionManagement.repositories),
      repositoriesMode: plain(base, settings.dependencyResolutionManagement.repositoriesMode)]
   }]
}

def settingsFacts = [:]
gradle.settingsEvaluated { settings ->
  def base = settings.rootDir
  settingsFacts.pluginManagementRepositories = repositoriesOf(settings.pluginManagement.repositories)
  settingsFacts.settingsPlugins = pluginsOf(base, settings.plugins)
  settingsFacts.settingsExtensions = extensionsOf(base, settings)
  settingsFacts.settingsBuildscript = buildscriptOf(settings)
  settingsFacts.settingsCore = settingsCoreOf(settings)
}

def outputFor = { invocation ->
  def outermost = invocation
  while (outermost.parent != null) outermost = outermost.parent
  def requested = outermost.startParameter.systemPropertiesArgs[MODEL_PROPERTY] ?: System.getProperty(MODEL_PROPERTY)
  if (requested == null) throw new GradleException(MODEL_PROPERTY + ' names no file to write the model to')
  def file = new File(requested)
  if (!file.isAbsolute()) file = new File(outermost.startParameter.currentDir, requested)
  if (invocation.parent == null) return file
  def identity = invocation.hasProperty('identityPath') ? invocation.identityPath.toString() : ':' + invocation.rootProject.name
  def suffix = identity.replaceAll(/^:/, '').replace(':', '-')
  new File(file.parentFile, (file.name - ~/\.json$/) + '-' + suffix + '.json')
}

def stringsIn
stringsIn = { Object value, Set found ->
  if (value instanceof CharSequence) found << value.toString()
  else if (value instanceof Map) value.values().each { stringsIn(it, found) }
  else if (value instanceof Iterable) value.each { stringsIn(it, found) }
  found
}

/**
 * Each string of the model that holds an environment variable's value, whole or inside it (a
 * token in a repository url), with the names of the variables it holds.
 *
 * @implNote compared here rather than hashed for the migrator, because the plugin has no digest
 * verb; only strings the model already carries are written, so no other variable's value reaches
 * the file. A value shorter than ENVIRONMENT_FLOOR is skipped, so a `17` or a `true` in the
 * environment cannot block a jdk or a flag that merely holds it.
 */
def ENVIRONMENT_FLOOR = 8
def environmentMatchesOf = { Map model ->
  def environment = System.getenv().findAll { name, value -> value != null && value.length() >= ENVIRONMENT_FLOOR }
  stringsIn(model, [] as Set).sort().collect { string ->
    [value: string, names: environment.findAll { name, value -> string.contains(value) }.keySet().sort()]
  }.findAll { !it.names.isEmpty() }
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
               settingsBuildscript: settingsFacts.settingsBuildscript ?: [repositories: [], resolved: [], errors: []],
               settingsCore: settingsFacts.settingsCore ?: [:],
               projects: gradle.rootProject.allprojects.collect { projectOf(base, it) }]
  model.environmentMatches = environmentMatchesOf(model)
  def file = outputFor(gradle)
  file.parentFile.mkdirs()
  file.setText(JsonOutput.prettyPrint(JsonOutput.toJson(model)), 'UTF-8')
}
]==]

return { SCRIPT = SCRIPT, PROPERTY = PROPERTY, IMPLIED_LAUNCHER = IMPLIED_LAUNCHER }
