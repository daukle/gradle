--- The part of the model dump's init script that reads build logic written as code: each build
--- script's top-level statements through its own DSL's parser, and the source lines of each
--- script-compiled task action from its class file. Spliced into `model_dump.SCRIPT` ahead of the
--- closures that call it, and it uses that script's `pathFrom`. D-165, sections 3 and 4.2.
local SCRIPT = [==[
def BYTE_ORDER_MARK = (char) 0xFEFF
def CARRIAGE_RETURN = (char) 13
def LINE_FEED = (char) 10

/**
 * A build script's text twice: `original`, the file without a leading UTF-8 BOM, which is what a
 * statement's `text` is cut from, and `parsed`, the same with every line break as LF, which both
 * parsers read; `originalOffsets` maps each offset into `parsed` (and its end) to one into `original`.
 *
 * @implNote the BOM goes because every Kotlin compiler reports it as an error element at offset 0
 * while counting it in every offset (P3), and the parsers read LF because the Kotlin PSI requires
 * it; the text stays the original bytes because a later task carries it verbatim (D-165).
 */
class ScriptSource {
  String original
  String parsed
  int[] originalOffsets

  String originalSlice(int start, int end) { original.substring(originalOffsets[start], originalOffsets[end]) }
}

def scriptSourceOf = { File file ->
  def original = file.getText('UTF-8')
  if (!original.isEmpty() && original.charAt(0) == BYTE_ORDER_MARK) original = original.substring(1)
  def parsed = new StringBuilder(original.length())
  def originalOffsets = new int[original.length() + 1]
  int at = 0
  while (at < original.length()) {
    originalOffsets[parsed.length()] = at
    char character = original.charAt(at)
    boolean crlf = character == CARRIAGE_RETURN && at + 1 < original.length() && original.charAt(at + 1) == LINE_FEED
    parsed.append(character == CARRIAGE_RETURN ? LINE_FEED : character)
    at += crlf ? 2 : 1
  }
  originalOffsets[parsed.length()] = original.length()
  new ScriptSource(original: original, parsed: parsed.toString(), originalOffsets: originalOffsets)
}

def lineStartsOf = { String text ->
  def starts = [0]
  for (int at = text.indexOf('\n'); at >= 0; at = text.indexOf('\n', at + 1)) starts << at + 1
  starts
}

def lineOfOffset = { List starts, int offset ->
  def found = Collections.binarySearch(starts, offset)
  found >= 0 ? found + 1 : -found - 1
}

def firstLineOf = { String message -> (message ?: '').readLines().find { true } ?: '' }

def isReflectiveWrapper = { Throwable failure ->
  (failure instanceof java.lang.reflect.UndeclaredThrowableException || failure instanceof java.lang.reflect.InvocationTargetException) &&
      failure.cause != null
}

/**
 * The failure an `unparsed` reason names: what a reflective call wrapped, and for Groovy's
 * compilation failure, whose message opens with a bare `startup failed:`, the syntax error it
 * collected first.
 */
def parserFailureOf = { Throwable thrown ->
  def failure = thrown
  while (isReflectiveWrapper(failure)) failure = failure.cause
  if (!(failure instanceof org.codehaus.groovy.control.MultipleCompilationErrorsException)) return failure
  def first = failure.errorCollector.errors.find { it.hasProperty('cause') && it.cause != null }
  first == null ? failure : first.cause
}

def unparsedReason = { Throwable thrown ->
  def failure = parserFailureOf(thrown)
  failure.getClass().name + ': ' + firstLineOf(failure.message)
}

def REGISTERING_CALLS = ['register', 'create', 'task', 'maybeCreate'] as Set

def statementOf = { ScriptSource source, List starts, int index, int start, int end, Map facts ->
  [index: index, text: source.originalSlice(start, end), startLine: lineOfOffset(starts, start),
   endLine: lineOfOffset(starts, Math.max(start, end - 1)), registers: facts.registers as List,
   defines: facts.defines as List, uses: facts.uses as List, definition: facts.definition]
}

/**
 * The identifiers a Groovy node names, and the tasks it registers: a string literal given to
 * `register`, `create` or `maybeCreate` on `tasks` or `project.tasks` or directly inside a
 * `tasks {}` block, and the name a `task` call gives, by literal or by the bare name Gradle's own
 * transform turns into one (`task gen {}`). The same calls on any other container are not tasks.
 */
class GroovyFacts extends org.codehaus.groovy.ast.ClassCodeVisitorSupport {
  Set registeringCalls
  Set registers = [] as LinkedHashSet
  Set uses = [] as TreeSet
  Set tasksBlocks = Collections.newSetFromMap(new IdentityHashMap())
  boolean insideTasksBlock

  protected org.codehaus.groovy.control.SourceUnit getSourceUnit() { null }

  static String stringConstant(expression) {
    expression instanceof org.codehaus.groovy.ast.expr.ConstantExpression && expression.value instanceof String ? expression.value : null
  }

  static String firstArgumentName(org.codehaus.groovy.ast.expr.MethodCallExpression call) {
    def arguments = call.arguments
    if (!(arguments instanceof org.codehaus.groovy.ast.expr.TupleExpression) || arguments.expressions.isEmpty()) return null
    def first = arguments.expressions[0]
    def literal = stringConstant(first)
    if (literal != null || call.methodAsString != 'task') return literal
    if (first instanceof org.codehaus.groovy.ast.expr.VariableExpression) return first.name
    first instanceof org.codehaus.groovy.ast.expr.MethodCallExpression && first.implicitThis ? first.methodAsString : null
  }

  static boolean isTasksReceiver(expression) {
    if (expression instanceof org.codehaus.groovy.ast.expr.VariableExpression) return expression.name == 'tasks'
    expression instanceof org.codehaus.groovy.ast.expr.PropertyExpression && expression.propertyAsString == 'tasks' &&
        expression.objectExpression instanceof org.codehaus.groovy.ast.expr.VariableExpression &&
        expression.objectExpression.name == 'project'
  }

  boolean isOnTaskContainer(org.codehaus.groovy.ast.expr.MethodCallExpression call) {
    if (call.methodAsString == 'task') return call.implicitThis
    call.implicitThis ? insideTasksBlock : isTasksReceiver(call.objectExpression)
  }

  void rememberTasksBlock(org.codehaus.groovy.ast.expr.MethodCallExpression call) {
    if (call.methodAsString != 'tasks' || !call.implicitThis) return
    def arguments = call.arguments
    if (!(arguments instanceof org.codehaus.groovy.ast.expr.TupleExpression) || arguments.expressions.isEmpty()) return
    def last = arguments.expressions[-1]
    if (last instanceof org.codehaus.groovy.ast.expr.ClosureExpression) tasksBlocks << last
  }

  void visitMethodCallExpression(org.codehaus.groovy.ast.expr.MethodCallExpression call) {
    def name = call.methodAsString
    if (name != null) uses << name
    if (registeringCalls.contains(name) && isOnTaskContainer(call)) {
      def registered = firstArgumentName(call)
      if (registered != null) registers << registered
    }
    rememberTasksBlock(call)
    super.visitMethodCallExpression(call)
  }

  void visitClosureExpression(org.codehaus.groovy.ast.expr.ClosureExpression closure) {
    def outer = insideTasksBlock
    insideTasksBlock = tasksBlocks.contains(closure)
    try { super.visitClosureExpression(closure) } finally { insideTasksBlock = outer }
  }

  void visitVariableExpression(org.codehaus.groovy.ast.expr.VariableExpression expression) {
    if (!expression.thisExpression && !expression.superExpression) uses << expression.name
    super.visitVariableExpression(expression)
  }

  void visitPropertyExpression(org.codehaus.groovy.ast.expr.PropertyExpression expression) {
    if (expression.propertyAsString != null) uses << expression.propertyAsString
    super.visitPropertyExpression(expression)
  }

  void visitConstructorCallExpression(org.codehaus.groovy.ast.expr.ConstructorCallExpression call) {
    uses << call.type.nameWithoutPackage
    super.visitConstructorCallExpression(call)
  }

  void visitClassExpression(org.codehaus.groovy.ast.expr.ClassExpression expression) {
    uses << expression.type.nameWithoutPackage
    super.visitClassExpression(expression)
  }
}

def isGroovyExtra = { expression ->
  (expression instanceof org.codehaus.groovy.ast.expr.VariableExpression && expression.name == 'ext') ||
  (expression instanceof org.codehaus.groovy.ast.expr.PropertyExpression && expression.propertyAsString == 'ext')
}

/** The names a Groovy `ext.name = ...`, `ext.set('name', ...)` or `ext { name = ... }` statement defines. */
def groovyExtraNamesOf = { expression ->
  if (expression instanceof org.codehaus.groovy.ast.expr.BinaryExpression && expression.operation.text == '=') {
    def left = expression.leftExpression
    if (left instanceof org.codehaus.groovy.ast.expr.PropertyExpression && isGroovyExtra(left.objectExpression)) return [left.propertyAsString]
    return []
  }
  if (!(expression instanceof org.codehaus.groovy.ast.expr.MethodCallExpression)) return []
  def arguments = expression.arguments.expressions
  if (expression.methodAsString == 'set' && isGroovyExtra(expression.objectExpression) && !arguments.isEmpty()) {
    def name = GroovyFacts.stringConstant(arguments[0])
    return name == null ? [] : [name]
  }
  if (expression.methodAsString != 'ext' || !expression.implicitThis || arguments.isEmpty()) return []
  def body = arguments[-1]
  if (!(body instanceof org.codehaus.groovy.ast.expr.ClosureExpression)) return []
  body.code.statements.collect { it instanceof org.codehaus.groovy.ast.stmt.ExpressionStatement ? it.expression : null }
      .findAll { it instanceof org.codehaus.groovy.ast.expr.BinaryExpression && it.operation.text == '=' &&
                 it.leftExpression instanceof org.codehaus.groovy.ast.expr.VariableExpression }
      .collect { it.leftExpression.name }
}

def groovyDeclaredNamesOf = { org.codehaus.groovy.ast.expr.DeclarationExpression declaration ->
  declaration.multipleAssignmentDeclaration ? declaration.tupleExpression.expressions*.name : [declaration.variableExpression.name]
}

/** The name an import brings in: its alias, else the simple name of a class or static member it names. */
def groovyImportedNameOf = { org.codehaus.groovy.ast.ImportNode node ->
  if (node.alias != null) return node.alias
  if (node.isStar()) return null
  node.fieldName ?: node.type?.nameWithoutPackage
}

def groovyDefinesOf = { node ->
  if (node instanceof org.codehaus.groovy.ast.ImportNode) return [groovyImportedNameOf(node)].findAll { it != null }
  if (node instanceof org.codehaus.groovy.ast.MethodNode) return [node.name]
  if (node instanceof org.codehaus.groovy.ast.ClassNode) return [node.nameWithoutPackage]
  if (!(node instanceof org.codehaus.groovy.ast.stmt.ExpressionStatement)) return []
  def expression = node.expression
  expression instanceof org.codehaus.groovy.ast.expr.DeclarationExpression ? groovyDeclaredNamesOf(expression) : groovyExtraNamesOf(expression)
}

def isGroovyDeclaration = { node ->
  node instanceof org.codehaus.groovy.ast.ImportNode || node instanceof org.codehaus.groovy.ast.MethodNode ||
  node instanceof org.codehaus.groovy.ast.ClassNode ||
  (node instanceof org.codehaus.groovy.ast.stmt.ExpressionStatement && node.expression instanceof org.codehaus.groovy.ast.expr.DeclarationExpression)
}

def groovyFactsOf = { node ->
  def visitor = new GroovyFacts(registeringCalls: REGISTERING_CALLS)
  if (node instanceof org.codehaus.groovy.ast.ClassNode) visitor.visitClass(node)
  else if (node instanceof org.codehaus.groovy.ast.MethodNode) visitor.visitMethod(node)
  else if (node instanceof org.codehaus.groovy.ast.stmt.Statement) node.visit(visitor)
  def defines = groovyDefinesOf(node)
  [registers: visitor.registers, defines: defines, uses: visitor.uses, definition: isGroovyDeclaration(node) || !defines.isEmpty()]
}

def groovyModuleOf = { String text ->
  def unit = new org.codehaus.groovy.control.CompilationUnit()
  def source = unit.addSource('build.gradle', text)
  unit.compile(org.codehaus.groovy.control.Phases.CONVERSION)
  source.AST
}

/** A module's top-level nodes: imports, statements, methods and declared classes. */
def groovyTopLevelOf = { module ->
  def imports = module.imports + module.starImports + module.staticImports.values() + module.staticStarImports.values()
  def classes = module.classes.findAll { !it.script && !(it instanceof org.codehaus.groovy.ast.InnerClassNode) }
  imports + module.statementBlock.statements + module.methods + classes
}

def offsetOf = { List starts, int line, int column -> starts[line - 1] + column - 1 }

def groovyStatementsOf = { ScriptSource source ->
  def starts = lineStartsOf(source.parsed)
  def located = groovyTopLevelOf(groovyModuleOf(source.parsed)).collect { node ->
    [node: node, start: offsetOf(starts, node.lineNumber, node.columnNumber), end: offsetOf(starts, node.lastLineNumber, node.lastColumnNumber)]
  }
  located.sort { it.start }.withIndex().collect { entry, position ->
    statementOf(source, starts, position + 1, entry.start, entry.end, groovyFactsOf(entry.node))
  }
}

def KOTLIN_JAR = ~/^(kotlin-compiler-embeddable|kotlin-stdlib|kotlin-reflect|kotlin-script-runtime|trove4j|annotations|kotlinx-coroutines-core-jvm)-.*\.jar$/

/**
 * The Kotlin parser of the running Gradle's own compiler, in a loader of its own over the
 * distribution's jars (M3, D-165).
 *
 * @implNote every PSI value is read through an explicit getter, because on 9.6.0 Groovy resolves
 * `file.script` to `isScript()`; the coroutines jar is on the path because 9.6.0's compiler needs
 * `kotlinx.coroutines.CoroutineScope` to start. The loader's parent is the platform loader, so
 * Gradle's own Kotlin never meets this one.
 */
class KotlinParser {
  URLClassLoader loader
  Object disposable
  Object factory
  Map classes = [:]

  Class type(String name) { classes.computeIfAbsent(name) { Class.forName(name, true, loader) } }

  def withLoader(Closure work) {
    def thread = Thread.currentThread()
    def previous = thread.contextClassLoader
    thread.contextClassLoader = loader
    try { work() } finally { thread.contextClassLoader = previous }
  }

  static KotlinParser open(File libDirectory, java.util.regex.Pattern wanted) {
    def jars = libDirectory.listFiles().findAll { it.name ==~ wanted }.sort { it.name }
    def parser = new KotlinParser(loader: new URLClassLoader(jars.collect { it.toURI().toURL() } as URL[], ClassLoader.platformClassLoader))
    try {
      parser.withLoader { parser.start() }
    } catch (Throwable failure) {
      try { parser.close() } catch (Throwable ignored) { }
      throw failure
    }
    parser
  }

  void start() {
    type('org.jetbrains.kotlin.cli.common.environment.UtilKt').getMethod('setIdeaIoUseFallback').invoke(null)
    disposable = type('org.jetbrains.kotlin.com.intellij.openapi.util.Disposer').getMethod('newDisposable').invoke(null)
    def configurationType = type('org.jetbrains.kotlin.config.CompilerConfiguration')
    def configuration = configurationType.getConstructor().newInstance()
    configuration.put(messageCollectorKey(), type('org.jetbrains.kotlin.cli.common.messages.MessageCollector').getField('Companion').get(null).getNONE())
    configuration.put(type('org.jetbrains.kotlin.config.CommonConfigurationKeys').getField('MODULE_NAME').get(null), 'daukle-migrate')
    def companion = type('org.jetbrains.kotlin.cli.jvm.compiler.KotlinCoreEnvironment').getField('Companion').get(null)
    def configFiles = type('org.jetbrains.kotlin.cli.jvm.compiler.EnvironmentConfigFiles').getField('JVM_CONFIG_FILES').get(null)
    def environment = companion.getClass().getMethod('createForProduction', type('org.jetbrains.kotlin.com.intellij.openapi.Disposable'),
                                                     configurationType, configFiles.getClass())
                               .invoke(companion, disposable, configuration, configFiles)
    factory = type('org.jetbrains.kotlin.psi.KtPsiFactory').getConstructor(type('org.jetbrains.kotlin.com.intellij.openapi.project.Project'), boolean)
                                                           .newInstance(environment.getProject(), false)
  }

  /** @implNote the key moved from `CLIConfigurationKeys` to `CommonConfigurationKeys` in Kotlin 2. */
  private Object messageCollectorKey() {
    try { return type('org.jetbrains.kotlin.config.CommonConfigurationKeys').getField('MESSAGE_COLLECTOR_KEY').get(null) }
    catch (NoSuchFieldException ignored) { return type('org.jetbrains.kotlin.cli.common.CLIConfigurationKeys').getField('MESSAGE_COLLECTOR_KEY').get(null) }
  }

  void close() {
    try {
      if (disposable != null) {
        withLoader { type('org.jetbrains.kotlin.com.intellij.openapi.util.Disposer').getMethod('dispose', type('org.jetbrains.kotlin.com.intellij.openapi.Disposable')).invoke(null, disposable) }
      }
    } finally { loader.close() }
  }

  Object parentOf(Object element, String name) {
    type('org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil').getParentOfType(element, type(name), true)
  }

  boolean is(String name, Object element) { element != null && type(name).isInstance(element) }

  List childrenOf(Object element, String name) {
    type('org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil').findChildrenOfType(element, type(name)) as List
  }

  Object firstChildOf(Object element, String name) {
    type('org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil').findChildOfType(element, type(name))
  }

  Object parse(String text) { withLoader { factory.createFile('build.gradle.kts', text) } }
}

/** Each Gradle home's parser, or the failure that kept it from starting, so no later script retries it. */
def kotlinParsers = [:]

def kotlinParserFor = { File gradleHome ->
  def parser = kotlinParsers.computeIfAbsent(gradleHome.path) {
    try { KotlinParser.open(new File(gradleHome, 'lib'), KOTLIN_JAR) } catch (Throwable failure) { failure }
  }
  if (parser instanceof Throwable) throw parser
  parser
}

def closeKotlinParsers = {
  kotlinParsers.values().findAll { it instanceof KotlinParser }.each { parser -> try { parser.close() } catch (Throwable ignored) { } }
  kotlinParsers.clear()
}

def kotlinStringOf = { KotlinParser parser, expression ->
  if (!parser.is('org.jetbrains.kotlin.psi.KtStringTemplateExpression', expression)) return null
  def entries = expression.getEntries() as List
  entries.every { parser.is('org.jetbrains.kotlin.psi.KtLiteralStringTemplateEntry', it) } ? entries.collect { it.getText() }.join('') : null
}

def kotlinCalleeNameOf = { KotlinParser parser, expression ->
  def selector = parser.is('org.jetbrains.kotlin.psi.KtQualifiedExpression', expression) ? expression.getSelectorExpression() : expression
  if (parser.is('org.jetbrains.kotlin.psi.KtCallExpression', selector)) selector = selector.getCalleeExpression()
  parser.is('org.jetbrains.kotlin.psi.KtNameReferenceExpression', selector) ? selector.getReferencedName() : null
}

def kotlinFirstArgumentOf = { call ->
  def arguments = call.getValueArguments() as List
  arguments.isEmpty() ? null : arguments[0].getArgumentExpression()
}

def DELEGATED_REGISTERING = ['registering', 'creating'] as Set
def KOTLIN_TASKS_RECEIVERS = ['tasks', 'project.tasks'] as Set

/** The receiver a call or delegate is qualified with, as text, or null for an unqualified one. */
def kotlinReceiverTextOf = { KotlinParser parser, node ->
  if (parser.is('org.jetbrains.kotlin.psi.KtQualifiedExpression', node)) return node.getReceiverExpression().getText()
  def parent = node.getParent()
  parser.is('org.jetbrains.kotlin.psi.KtQualifiedExpression', parent) && parent.getSelectorExpression() == node ? parent.getReceiverExpression().getText() : null
}

/** Whether an element's nearest enclosing lambda is the trailing lambda of a `tasks {}` call. */
def isInsideKotlinTasksBlock = { KotlinParser parser, element ->
  def lambda = parser.parentOf(element, 'org.jetbrains.kotlin.psi.KtLambdaExpression')
  def call = lambda?.getParent()?.getParent()
  parser.is('org.jetbrains.kotlin.psi.KtLambdaArgument', lambda?.getParent()) && parser.is('org.jetbrains.kotlin.psi.KtCallExpression', call) &&
      kotlinCalleeNameOf(parser, call) == 'tasks' && kotlinReceiverTextOf(parser, call) in [null, 'project']
}

def isOnKotlinTaskContainer = { KotlinParser parser, node, element ->
  def receiver = kotlinReceiverTextOf(parser, node)
  receiver == null ? isInsideKotlinTasksBlock(parser, element) : receiver in KOTLIN_TASKS_RECEIVERS
}

def kotlinRegisteredNameOf = { KotlinParser parser, node ->
  if (parser.is('org.jetbrains.kotlin.psi.KtProperty', node)) {
    def delegate = node.getDelegateExpression()
    boolean registering = kotlinCalleeNameOf(parser, delegate) in DELEGATED_REGISTERING && isOnKotlinTaskContainer(parser, delegate, node)
    return registering ? node.getName() : null
  }
  def name = kotlinCalleeNameOf(parser, node)
  if (name == 'task') return kotlinReceiverTextOf(parser, node) == null ? kotlinStringOf(parser, kotlinFirstArgumentOf(node)) : null
  name in REGISTERING_CALLS && isOnKotlinTaskContainer(parser, node, node) ? kotlinStringOf(parser, kotlinFirstArgumentOf(node)) : null
}

def kotlinRegistersOf = { KotlinParser parser, element ->
  def candidates = [element] + parser.childrenOf(element, 'org.jetbrains.kotlin.psi.KtProperty') +
                   parser.childrenOf(element, 'org.jetbrains.kotlin.psi.KtCallExpression')
  candidates.sort { it.getTextRange().getStartOffset() }.collect { kotlinRegisteredNameOf(parser, it) }.findAll { it != null }.unique()
}

def isKotlinExtra = { expression -> expression != null && expression.getText() ==~ /(.*\.)?(extra|ext)/ }

/** The name a Kotlin `extra["name"] = ...` or `extra.set("name", ...)` statement defines. */
def kotlinExtraNameOf = { KotlinParser parser, body ->
  if (parser.is('org.jetbrains.kotlin.psi.KtBinaryExpression', body) && body.getOperationReference().getText() == '=') {
    def left = body.getLeft()
    if (!parser.is('org.jetbrains.kotlin.psi.KtArrayAccessExpression', left) || !isKotlinExtra(left.getArrayExpression())) return null
    def indices = left.getIndexExpressions() as List
    return indices.size() == 1 ? kotlinStringOf(parser, indices[0]) : null
  }
  if (!parser.is('org.jetbrains.kotlin.psi.KtDotQualifiedExpression', body) || !isKotlinExtra(body.getReceiverExpression())) return null
  def call = body.getSelectorExpression()
  kotlinCalleeNameOf(parser, call) == 'set' ? kotlinStringOf(parser, kotlinFirstArgumentOf(call)) : null
}

def KOTLIN_DECLARATIONS = ['org.jetbrains.kotlin.psi.KtImportDirective', 'org.jetbrains.kotlin.psi.KtProperty',
                           'org.jetbrains.kotlin.psi.KtNamedFunction', 'org.jetbrains.kotlin.psi.KtClassOrObject',
                           'org.jetbrains.kotlin.psi.KtTypeAlias']

def kotlinImportedNameOf = { directive ->
  if (directive.getAliasName() != null) return directive.getAliasName()
  directive.isAllUnder() || directive.getImportedFqName() == null ? null : directive.getImportedFqName().shortName().asString()
}

def kotlinDefinesOf = { KotlinParser parser, element ->
  if (parser.is('org.jetbrains.kotlin.psi.KtImportDirective', element)) return [kotlinImportedNameOf(element)].findAll { it != null }
  if (KOTLIN_DECLARATIONS.any { parser.is(it, element) }) return [element.getName()].findAll { it != null }
  if (!parser.is('org.jetbrains.kotlin.psi.KtScriptInitializer', element)) return []
  [kotlinExtraNameOf(parser, element.getBody())].findAll { it != null }
}

def kotlinFactsOf = { KotlinParser parser, element ->
  def uses = parser.childrenOf(element, 'org.jetbrains.kotlin.psi.KtNameReferenceExpression').collect { it.getReferencedName() } as TreeSet
  def defines = kotlinDefinesOf(parser, element)
  [registers: kotlinRegistersOf(parser, element), defines: defines, uses: uses,
   definition: KOTLIN_DECLARATIONS.any { parser.is(it, element) } || !defines.isEmpty()]
}

/** The first syntax error the PSI holds, as an `unparsed` reason: the compiler does not throw on one. */
def kotlinSyntaxErrorOf = { KotlinParser parser, file, List starts ->
  def error = parser.firstChildOf(file, 'org.jetbrains.kotlin.com.intellij.psi.PsiErrorElement')
  if (error == null) return null
  'PsiErrorElement: ' + error.getErrorDescription() + ' at line ' + lineOfOffset(starts, error.getTextRange().getStartOffset())
}

def kotlinTopLevelOf = { file ->
  def imports = file.getImportList() == null ? [] : file.getImportList().getImports() as List
  def script = file.getScript()
  def statements = script == null ? [] : script.getBlockExpression().getStatements() as List
  (imports + statements).sort { it.getTextRange().getStartOffset() }
}

def kotlinStatementsOf = { KotlinParser parser, ScriptSource source ->
  def starts = lineStartsOf(source.parsed)
  parser.withLoader {
    def file = parser.parse(source.parsed)
    def error = kotlinSyntaxErrorOf(parser, file, starts)
    if (error != null) return [unparsed: error]
    [statements: kotlinTopLevelOf(file).withIndex().collect { element, position ->
      def range = element.getTextRange()
      statementOf(source, starts, position + 1, range.getStartOffset(), range.getEndOffset(), kotlinFactsOf(parser, element))
    }]
  }
}

/**
 * A build script's top-level statements with the facts the migrator selects by (D-165, section 4.1),
 * or `unparsed` with the reason its DSL's parser gave; null for a project with no build file.
 */
def scriptInventoryOf = { File base, File gradleHome, project ->
  def file = project.buildFile
  if (!file.isFile()) return null
  def kotlin = file.name.endsWith('.kts')
  def inventory = [path: pathFrom(base, file), dsl: kotlin ? 'kotlin' : 'groovy']
  try {
    def source = scriptSourceOf(file)
    inventory.lineEnding = source.original.contains('\r\n') ? 'crlf' : 'lf'
    inventory + (kotlin ? kotlinStatementsOf(kotlinParserFor(gradleHome), source) : [statements: groovyStatementsOf(source)])
  } catch (Throwable failure) {
    inventory + [unparsed: unparsedReason(failure)]
  }
}

def CONSTANT_POOL_SIZES = [3: 4, 4: 4, 5: 8, 6: 8, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4, 12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2]
def WIDE_CONSTANTS = [5, 6] as Set

def skipBytes = { DataInputStream input, int count -> input.readFully(new byte[count]) }

def readUtf8Constants = { DataInputStream input ->
  def utf8 = [:]
  int count = input.readUnsignedShort()
  for (int index = 1; index < count; index++) {
    int tag = input.readUnsignedByte()
    if (tag == 1) { utf8[index] = input.readUTF(); continue }
    if (!CONSTANT_POOL_SIZES.containsKey(tag)) throw new IllegalStateException('constant pool tag ' + tag)
    skipBytes(input, CONSTANT_POOL_SIZES[tag])
    if (WIDE_CONSTANTS.contains(tag)) index++
  }
  utf8
}

def readLineNumbers = { DataInputStream input, List lines ->
  int count = input.readUnsignedShort()
  count.times { skipBytes(input, 2); lines << input.readUnsignedShort() }
}

def readCodeLines = { DataInputStream input, Map utf8, List lines ->
  skipBytes(input, 4)
  skipBytes(input, input.readInt())
  skipBytes(input, 8 * input.readUnsignedShort())
  input.readUnsignedShort().times {
    def name = utf8[input.readUnsignedShort()]
    int length = input.readInt()
    if (name == 'LineNumberTable') readLineNumbers(input, lines) else skipBytes(input, length)
  }
}

def readMembers = { DataInputStream input, Map utf8, List lines ->
  input.readUnsignedShort().times {
    skipBytes(input, 6)
    input.readUnsignedShort().times {
      def name = utf8[input.readUnsignedShort()]
      int length = input.readInt()
      if (name == 'Code') readCodeLines(input, utf8, lines) else skipBytes(input, length)
    }
  }
}

/** A class file's `SourceFile` and the lines its `LineNumberTable`s name (M4, D-165). */
def readClassFile = { DataInputStream input ->
  skipBytes(input, 8)
  def utf8 = readUtf8Constants(input)
  skipBytes(input, 6)
  skipBytes(input, 2 * input.readUnsignedShort())
  def lines = []
  readMembers(input, utf8, [])
  readMembers(input, utf8, lines)
  def sourceFile = null
  input.readUnsignedShort().times {
    def name = utf8[input.readUnsignedShort()]
    int length = input.readInt()
    if (name == 'SourceFile') sourceFile = utf8[input.readUnsignedShort()] else skipBytes(input, length)
  }
  [sourceFile: sourceFile, lines: lines]
}

/** A class's `SourceFile`, which Groovy writes as an absolute path and Kotlin as a bare file name. */
def sourceFileFrom = { File base, String sourceFile ->
  sourceFile != null && new File(sourceFile).isAbsolute() ? pathFrom(base, sourceFile) : sourceFile
}

/**
 * Where a script-compiled action's class came from: its `SourceFile`, and the LAST line its code
 * names, which is the line that places it in a statement.
 *
 * @implNote the last line, because Kotlin on 7.6.4 adds a stray line 1 to a lambda's table while
 * keeping the right last line (M4, D-165).
 */
def actionLinesOf = { File base, Class type ->
  try {
    def stream = type.classLoader?.getResourceAsStream(type.name.replace('.', '/') + '.class')
    if (stream == null) return [:]
    def read = stream.withCloseable { readClassFile(new DataInputStream(new BufferedInputStream(it))) }
    def sourceFile = sourceFileFrom(base, read.sourceFile)
    read.lines.isEmpty() ? [sourceFile: sourceFile] : [sourceFile: sourceFile, lastLine: read.lines.max()]
  } catch (Throwable ignored) {
    [:]
  }
}
]==]

return { SCRIPT = SCRIPT }
