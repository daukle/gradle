import java.util.Locale

plugins {
    `java-library`
}

repositories {
    mavenCentral()
}

dependencies {
    api("org.apache.commons:commons-lang3:3.14.0")
}

tasks.register("stamp") {
    doLast {
        println("stamped".uppercase(Locale.ROOT))
    }
}
