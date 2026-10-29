plugins {
    `java-library`
}

configurations {
    val toolCompile = create("toolCompile")
    compileClasspath.configure {
        extendsFrom(toolCompile)
    }
}

version = "1.0.0"

dependencies {
    "toolCompile"(project(":lib"))
}

val runTool by tasks.register<JavaExec>("runTool") {
    dependsOn(tasks.classes)
    classpath += configurations["toolCompile"]
    classpath += sourceSets.main.get().output.classesDirs
    mainClass.set("example.app.App")
}
