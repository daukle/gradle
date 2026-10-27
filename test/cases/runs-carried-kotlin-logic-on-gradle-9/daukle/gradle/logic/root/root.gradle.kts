import org.barfuin.gradle.taskinfo.TaskInfoExtension

val generateConfig by tasks.registering {
    doLast { println("P2 generateConfig ran") }
}

tasks.compileJava {
    options.encoding = "UTF-8"
    dependsOn(generateConfig)
}

sourceSets.main {
    resources.srcDir("extra-resources")
}

configure<TaskInfoExtension> {
    println("carried configure of " + TaskInfoExtension::class.simpleName)
}

taskinfo {
    println("carried taskinfo accessor")
}
