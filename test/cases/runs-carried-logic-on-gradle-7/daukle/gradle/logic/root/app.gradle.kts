val generateConfig by tasks.registering {
    doLast { println("app generateConfig ran in " + projectDir.name) }
}

tasks.compileJava {
    dependsOn(generateConfig)
}
