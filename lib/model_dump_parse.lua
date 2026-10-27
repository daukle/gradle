--- The part of the model dump's init script that reads build logic written as code: each build
--- script's top-level statements through its own DSL's parser, and the source lines of each
--- script-compiled task action from its class file. Spliced into `model_dump.SCRIPT` ahead of the
--- closures that call it, and it uses that script's `pathFrom`. D-165, sections 3 and 4.2.
local SCRIPT = [==[
def BYTE_ORDER_MARK = (char) 0xFEFF

/**
 * A build script's text as both parsers read it: line breaks as LF, which the Kotlin PSI requires,
 * and without a leading UTF-8 BOM, which every Kotlin compiler reports as an error element at offset
 * 0 while counting it in every offset (P3, D-165).
 */
def sourceTextOf = { File file ->
  def text = file.getText('UTF-8').replace('\r\n', '\n').replace('\r', '\n')
  !text.isEmpty() && text.charAt(0) == BYTE_ORDER_MARK ? text.substring(1) : text
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

/**
 * The failure an `unparsed` reason names: for Groovy's compilation failure, whose message opens with
 * a bare `startup failed:`, the syntax error it collected first.
 */
def parserFailureOf = { Throwable failure ->
  if (!(failure instanceof org.codehaus.groovy.control.MultipleCompilationErrorsException)) return failure
  def first = failure.errorCollector.errors.find { it.hasProperty('cause') && it.cause != null }
  first == null ? failure : first.cause
}

def unparsedReason = { Throwable thrown ->
  def failure = parserFailureOf(thrown)
  failure.getClass().name + ': ' + firstLineOf(failure.message)
}

def REGISTERING_CALLS = ['register', 'create', 'task', 'maybeCreate'] as Set

def statementOf = { String text, List starts, int index, int start, int end, Map facts ->
  [index: index, text: text.substring(start, end), startLine: lineOfOffset(starts, start),
   endLine: lineOfOffset(starts, Math.max(start, end - 1)), registers: facts.registers as List,
   defines: facts.defines as List, uses: facts.uses as List, definition: facts.definition]
}

/**
 * The identifiers a Groovy node names and the tasks it registers by a string literal, or for `task`
 * by the bare name Gradle's own transform turns into one (`task gen {}`).
 */
class GroovyFacts extends org.codehaus.groovy.ast.ClassCodeVisitorSupport {
  Set registeringCalls
  Set registers = [] as LinkedHashSet
  Set uses = [] as TreeSet

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

  void visitMethodCallExpression(org.codehaus.groovy.ast.expr.MethodCallExpression call) {
    def name = call.methodAsString
    if (name != null) uses << name
    if (registeringCalls.contains(name)) {
      def registered = firstArgumentName(call)
      if (registered != null) registers << registered
    }
    super.visitMethodCallExpression(call)
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

def groovyDefinesOf = { node ->
  if (node instanceof org.codehaus.groovy.ast.ImportNode) return node.alias == null ? [] : [node.alias]
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

/** A module's top-level nodes in source order: imports, statements, methods and declared classes. */
def groovyTopLevelOf = { module ->
  def imports = module.imports + module.starImports + module.staticImports.values() + module.staticStarImports.values()
  def classes = module.classes.findAll { !it.script && !(it instanceof org.codehaus.groovy.ast.InnerClassNode) }
  (imports + module.statementBlock.statements + module.methods + classes).sort { [it.lineNumber, it.columnNumber] }
}

def offsetOf = { List starts, int line, int column -> starts[line - 1] + column - 1 }

def groovyStatementsOf = { String text ->
  def starts = lineStartsOf(text)
  groovyTopLevelOf(groovyModuleOf(text)).withIndex().collect { node, position ->
    statementOf(text, starts, position + 1, offsetOf(starts, node.lineNumber, node.columnNumber),
                offsetOf(starts, node.lastLineNumber, node.lastColumnNumber), groovyFactsOf(node))
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
    parser.withLoader { parser.start() }
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
    try { withLoader { type('org.jetbrains.kotlin.com.intellij.openapi.util.Disposer').getMethod('dispose', type('org.jetbrains.kotlin.com.intellij.openapi.Disposable')).invoke(null, disposable) } }
    finally { loader.close() }
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

def kotlinParsers = [:]

def kotlinParserFor = { File gradleHome ->
  kotlinParsers.computeIfAbsent(gradleHome.path) { KotlinParser.open(new File(gradleHome, 'lib'), KOTLIN_JAR) }
}

def closeKotlinParsers = {
  kotlinParsers.values().each { parser -> try { parser.close() } catch (Throwable ignored) { } }
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

def kotlinRegisteredNameOf = { KotlinParser parser, node ->
  if (parser.is('org.jetbrains.kotlin.psi.KtProperty', node)) {
    return kotlinCalleeNameOf(parser, node.getDelegateExpression()) in DELEGATED_REGISTERING ? node.getName() : null
  }
  kotlinCalleeNameOf(parser, node) in REGISTERING_CALLS ? kotlinStringOf(parser, kotlinFirstArgumentOf(node)) : null
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

def kotlinStatementsOf = { KotlinParser parser, String text ->
  def starts = lineStartsOf(text)
  parser.withLoader {
    def file = parser.parse(text)
    def error = kotlinSyntaxErrorOf(parser, file, starts)
    if (error != null) return [unparsed: error]
    [statements: kotlinTopLevelOf(file).withIndex().collect { element, position ->
      def range = element.getTextRange()
      statementOf(text, starts, position + 1, range.getStartOffset(), range.getEndOffset(), kotlinFactsOf(parser, element))
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
    def text = sourceTextOf(file)
    inventory + (kotlin ? kotlinStatementsOf(kotlinParserFor(gradleHome), text) : [statements: groovyStatementsOf(text)])
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

/**
 * Where a script-compiled action's class came from: its `SourceFile`, which Groovy writes as an
 * absolute path and Kotlin as a bare file name, and the LAST line its code names, which is the line
 * that places it in a statement.
 *
 * @implNote the last line, because Kotlin on 7.6.4 adds a stray line 1 to a lambda's table while
 * keeping the right last line (M4, D-165).
 */
def sourceFileFrom = { File base, String sourceFile ->
  sourceFile != null && new File(sourceFile).isAbsolute() ? pathFrom(base, sourceFile) : sourceFile
}

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
