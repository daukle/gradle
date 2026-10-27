import java.util.Locale

plugins {
    java
}

tasks.register("stamp") {
    doLast {
        println("stamped".uppercase(Locale.ROOT))
    }
}
