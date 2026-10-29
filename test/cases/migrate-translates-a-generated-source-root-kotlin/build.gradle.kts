plugins {
    java
}

val generatedConfigDir = project.layout.buildDirectory.dir("generated/config").get()

val generateConfig by tasks.registering {
    val file = generatedConfigDir.file("example/Config.java").asFile
    outputs.file(file)
    doLast {
        file.parentFile.mkdirs()
        file.writeText("package example; class Config { static final String VALUE = \"1\"; }")
    }
}

tasks.compileJava.configure {
    dependsOn(generateConfig)
}

sourceSets.main.configure { java.srcDir(generatedConfigDir) }
