tasks.compileJava {
    doLast { println("included carried reads " + rootProject.file("note.txt").readText().trim()) }
}
