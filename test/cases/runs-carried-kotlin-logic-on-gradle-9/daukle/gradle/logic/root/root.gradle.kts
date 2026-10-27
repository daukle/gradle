/*
 * A header comment, an annotation and a line comment ahead of the import,
 * which the wrapper must still lift above its own plugins {} block.
 */
@file:Suppress("DEPRECATION")

// the extension's own class, configured below
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
