local distributions = daukle.require("lib/distributions")
local jdks = daukle.require("java:lib/jdks")

local function provisioned_jdk(context, jdk_version)
  local jdk = jdks.for_host{ os = context.host.os, arch = context.host.arch, version = jdk_version }
  local root = daukle.provision{ url = jdk.url, sha256 = jdk.sha256, as = "temurin " .. jdk_version }
  return root, jdk
end

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

--- The end of a failed run's stderr, which is where Gradle says why.
local function stderr_tail(result)
  local text = result.stderr or ""
  if #text <= STDERR_SHOWN then return text end
  return "..." .. string.sub(text, -STDERR_SHOWN)
end

return { run = run, jdk_home = jdk_home, stderr_tail = stderr_tail }
