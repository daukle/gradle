plugins {
  `java-library`
}

group = "example"
version = "1.0"

tasks.compileJava {
  val gson = libs.versions.gson.get()
  println("catalog gson is " + gson)
  doLast {
    println("compiled beside catalog gson " + gson)
  }
}
