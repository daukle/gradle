--- The part of the model dump's init script that keeps environment variable values out of the
--- model file: each string holding one is rewritten to `${env:NAME}` and named, so the migrator
--- blocks wherever it would write it. Spliced into `model_dump.SCRIPT` ahead of the closure that
--- writes the model.

--- What stands in a model string for an environment variable's value: the
--- marker, the variable's name, and a closing brace.
local ENVIRONMENT_MARKER = "${env:"

local SCRIPT = [==[
def ENVIRONMENT_FLOOR = 8
def ENVIRONMENT_MARKER = ']==] .. ENVIRONMENT_MARKER .. [==['

/**
 * A model string with every environment variable value it holds, whole or inside it (a token in a
 * repository url), replaced by `${env:<name>}`, the longest value first; a string that held one is
 * remembered in `matches` with the names of the variables it held.
 */
def redactedString = { String text, Map environment, Map matches ->
  def held = environment.findAll { name, value -> text.contains(value) }
  if (held.isEmpty()) return text
  def redacted = text
  held.sort { -it.value.length() }.each { name, value -> redacted = redacted.replace(value, ENVIRONMENT_MARKER + name + '}') }
  matches[redacted] = held.keySet().sort()
  redacted
}

def redacted
redacted = { Object value, Map environment, Map matches ->
  if (value instanceof CharSequence) return redactedString(value.toString(), environment, matches)
  if (value instanceof Map) return value.collectEntries { key, item -> [key, redacted(item, environment, matches)] }
  if (value instanceof Iterable) return value.collect { redacted(it, environment, matches) }
  value
}

/**
 * The model with no environment variable's value in it, and `environmentMatches` naming each string
 * that held one, which the migrator then blocks wherever it would write it.
 *
 * @implNote compared here rather than hashed for the migrator, because the plugin has no digest
 * verb, and redacted because the model file lies in `build/`, where a secret has no place either. A
 * value shorter than ENVIRONMENT_FLOOR is skipped, so a `17` or a `true` in the environment cannot
 * block a jdk or a flag that merely holds it. Map keys are not redacted: they are the model's own
 * structure and Gradle's names.
 */
def withoutEnvironment = { Map model ->
  def environment = System.getenv().findAll { name, value -> value != null && value.length() >= ENVIRONMENT_FLOOR }
  def matches = [:]
  def safe = redacted(model, environment, matches)
  safe.environmentMatches = matches.keySet().sort().collect { [value: it, names: matches[it]] }
  safe
}

/**
 * The model as written: `withoutEnvironment`'s, except that each project's `script` inventory is
 * kept as it was read.
 *
 * @implNote the inventory is source text already on disk, which a later task carries verbatim, and a
 * statement redacted to `${env:...}` would no longer compile; every value the build evaluated is
 * still redacted and still blocks (D-165).
 */
def writableModel = { Map model ->
  def scripts = model.projects.collect { it.remove('script') }
  def safe = withoutEnvironment(model)
  safe.projects.eachWithIndex { project, index -> project.script = scripts[index] }
  safe
}
]==]

--- Whether a model string held an environment variable's value.
local function holds_environment(text)
  return type(text) == "string" and string.find(text, ENVIRONMENT_MARKER, 1, true) ~= nil
end

--- The names of the environment variables whose values a string held, or nil.
local function environment_names(text)
  if not holds_environment(text) then return nil end
  local names, from = {}, 1
  while true do
    local first, last = string.find(text, ENVIRONMENT_MARKER, from, true)
    if first == nil then break end
    local close = string.find(text, "}", last + 1, true)
    if close == nil then break end
    names[#names + 1] = string.sub(text, last + 1, close - 1)
    from = close + 1
  end
  return names
end

return { SCRIPT = SCRIPT, holds_environment = holds_environment, environment_names = environment_names }
