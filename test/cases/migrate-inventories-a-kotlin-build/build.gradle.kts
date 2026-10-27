import java.time.LocalDate as Day

plugins {
    java
}

val banner = """a } ${"b"} c"""

fun helper() {
    tasks.register("fromHelper") {
        doLast { println("helper ran") }
    }
}

helper()

val gen by tasks.registering {
    doLast {
        println("gen ran $banner")
    }
}

tasks.compileJava {
    options.encoding = "UTF-8"
    dependsOn(gen)
}

extra["release"] = "17"
