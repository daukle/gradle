plugins {
  `java-library`
}

group = "example"
version = "1.0"

tasks.register("versions") {
  description = "${libs.versions.gson.get()} ${libs.plugins.taskinfo.get().pluginId}"
  doLast {
    println(libs.versions.gson.get())
  }
}
