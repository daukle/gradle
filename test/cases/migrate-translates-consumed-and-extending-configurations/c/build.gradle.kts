plugins {
    `java-library`
}

version = "1.0.0"

configurations {
    val teavm = create("teavm")
    teavm.extendsFrom(compileClasspath.get())
    create("js")
}

dependencies {
    "teavm"(project(":impl"))
    "js"(project(":p", "js"))
}

val show by tasks.registering {
    val js = configurations["js"]
    val teavm = configurations["teavm"]
    inputs.files(js)
    doLast {
        println("JS=" + js.files.size)
        println("TEAVM=" + teavm.files.size)
    }
}
