local gradle = daukle.config.toolchains.gradle
gradle.configurations = gradle.configurations or {}
gradle.configurations.checkstyle = {{
  url = "https://repo1.maven.org/maven2/com/puppycrawl/tools/checkstyle/10.12.0/checkstyle-10.12.0.jar",
  sha256 = "a8b15de4e5b0f3157f6a5d3bda9aacece3a793a9fbe133844817434afa60c820",
  as = "checkstyle 10.12.0",
}}
