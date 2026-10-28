plugins {
  `java-library`
}

group = "example"
version = "1.0"

tasks.register("versions") {
  doLast {
    println(libs.versions.gson.get())
  }
}
