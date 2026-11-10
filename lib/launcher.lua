local distributions = daukle.require("lib/distributions")
local jdks = daukle.require("java:lib/jdks")

local function provisioned_jdk(context, jdk_version)
  local jdk = jdks.for_host{ os = context.host.os, arch = context.host.arch, version = jdk_version }
  local root = daukle.provision{ url = jdk.url, sha256 = jdk.sha256, as = "temurin " .. jdk_version }
  return root, jdk
end

--- How long an idle Gradle daemon stays alive: Gradle's own three hours left four daemons holding
--- 3.3 GB on one machine (D-167), and `--no-daemon` would lose the reuse between a migration's runs
--- and between a user's builds. Measured honoured from the command line on 7.6.4, 8.13 and 9.6.0.
local DAEMON_IDLE_MILLISECONDS = 300000

--- Runs Gradle `gradle_version` on the JDK `jdk_version`, both provisioned, with
--- `arguments` after the launcher's own.
---
--- @implNote the launcher jar rather than `bin/gradle`, because that is a POSIX
--- shell script and `bin/gradle.bat` a batch file, and neither is a program
--- daukle can start on every host. The jar is what both scripts eventually
--- exec. Starting it with the provisioned java is also what makes JAVA_HOME
--- unnecessary: Gradle reports the daemon JVM as "no JDK specified, using
--- current Java home", which is the one daukle provisioned.
local function run(context, gradle_version, jdk_version, arguments, options)
  local pick = distributions.for_version(gradle_version)
  local gradle_root = daukle.provision{ url = pick.url, sha256 = pick.sha256,
                                        as = "gradle " .. pick.version }
  local jdk_root, jdk = provisioned_jdk(context, jdk_version)

  local java = jdk_root:tool(jdk.home .. "/bin/java"
                             .. (context.host.os == "windows" and ".exe" or ""))
  local argv = {
    "-classpath", gradle_root:path(pick.home .. "/lib/gradle-launcher-" .. pick.version .. ".jar"),
    "org.gradle.launcher.GradleMain",
    "-Dorg.gradle.daemon.idletimeout=" .. DAEMON_IDLE_MILLISECONDS,
  }
  for index = 1, #arguments do argv[#argv + 1] = arguments[index] end
  return daukle.exec(java, argv, options)
end

--- The provisioned JDK's home directory, as an absolute path.
local function jdk_home(context, jdk_version)
  local root, jdk = provisioned_jdk(context, jdk_version)
  return root:dir(jdk.home)
end

local STDERR_SHOWN = 2000

local function tail(text)
  if #text <= STDERR_SHOWN then return text end
  return "..." .. string.sub(text, -STDERR_SHOWN)
end

local function section(text, heading)
  local start = string.find(text, "* " .. heading .. ":\n", 1, true)
  if start == nil then return nil end
  local finish = string.find(text, "\n\n* ", start, true)
  return string.sub(text, start, (finish or #text + 1) - 1)
end

--- Why a failed run failed: Gradle's "What went wrong" section, then its
--- "Where", or the end of stderr when it printed neither.
---
--- @implNote the reason comes first because core cuts an error at 512 bytes,
--- and a build's own warnings (the Android SDK's XML namespace lines) can fill
--- that before the reason is reached, as termux's did (D-230).
local function failure_text(result)
  local text = string.gsub(result.stderr or "", "\r\n", "\n")
  local wrong = section(text, "What went wrong")
  if wrong == nil then return tail(text) end
  local where = section(text, "Where")
  return tail(wrong .. (where ~= nil and "\n" .. where or ""))
end

--- The flags every migration run passes to keep the configuration cache off.
---
--- @implNote isolated projects is turned off with it, because a build enabling
--- `org.gradle.unsafe.isolated-projects` refuses `--no-configuration-cache`
--- outright: okhttp does, measured on 7.6.4 and 9.8.2, and the command line
--- wins over its `gradle.properties`.
local NO_CONFIGURATION_CACHE = { "--no-configuration-cache", "-Dorg.gradle.unsafe.isolated-projects=false" }

return { run = run, jdk_home = jdk_home, failure_text = failure_text,
         NO_CONFIGURATION_CACHE = NO_CONFIGURATION_CACHE }
