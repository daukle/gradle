plugins {
    `java-library`
}

version = "1.0.0"

configurations {
    create("js")
}

val zipJs by tasks.registering(Zip::class) {
    from("src")
    archiveFileName = "p-js.zip"
    destinationDirectory = layout.buildDirectory.dir("js")
}

artifacts.add("js", zipJs)
