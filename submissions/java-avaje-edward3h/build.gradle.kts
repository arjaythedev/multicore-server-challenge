plugins {
    java
    application
    id("org.ethelred.kiwiproc") version "1.0"
    id("com.diffplug.spotless") version "8.10.4"
}

repositories {
    mavenCentral()
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(26)
    }
}

val avajeHttp = "3.12.1"
val avajeInject = "12.7"
val avajeJsonb = "3.16"
val avajeValidator = "2.18"
val checkerFramework = "4.3.1"

val checker: Configuration by configurations.creating

dependencies {
    checker("org.checkerframework:checker:$checkerFramework")
    implementation("io.avaje:avaje-http-api:$avajeHttp")
    implementation("io.avaje:avaje-inject:$avajeInject")
    implementation("io.avaje:avaje-jsonb:$avajeJsonb")
    implementation("io.helidon.webserver:helidon-webserver:4.5.6")
    implementation("jakarta.inject:jakarta.inject-api:2.0.1")
    implementation("com.zaxxer:HikariCP:7.1.0")
    implementation("org.postgresql:postgresql:42.7.14")
    implementation("at.favre.lib:bcrypt:0.10.2")
    implementation("org.jspecify:jspecify:1.0.0")
    implementation("io.avaje:avaje-validator:$avajeValidator")
    implementation("io.avaje:avaje-validator-constraints:$avajeValidator")

    annotationProcessor("io.avaje:avaje-http-helidon-generator:$avajeHttp")
    annotationProcessor("io.avaje:avaje-inject-generator:$avajeInject")
    annotationProcessor("io.avaje:avaje-jsonb-generator:$avajeJsonb")
    annotationProcessor("io.avaje:avaje-validator-generator:$avajeValidator")
}

application {
    mainClass = "conduit.Main"
}

tasks.withType<JavaCompile>().configureEach {
    options.release = 26
    options.encoding = "UTF-8"
}

// Optional: ./gradlew checkNullness runs the Checker Framework's Nullness Checker over our own sources. It is not
// part of build, check or installDist (and so not of build.sh). The generated sources are already compiled by
// compileJava, so they are only on the classpath here, not checked.
val checkNullness by tasks.registering(JavaCompile::class) {
    description = "Runs the Checker Framework Nullness Checker on src/main/java."
    group = "verification"
    val main = sourceSets.main.get()
    dependsOn(tasks.compileJava)
    source = main.java
    classpath = main.compileClasspath + main.output.classesDirs + checker
    destinationDirectory = layout.buildDirectory.dir("checker-classes")
    options.annotationProcessorPath = checker
    options.release = 26
    options.encoding = "UTF-8"
    options.compilerArgs.addAll(
        listOf(
            "-proc:full",
            "-processor",
            "org.checkerframework.checker.nullness.NullnessChecker",
            "-Xlint:-processing",
        ),
    )
    options.isFork = true
    options.forkOptions.jvmArgs =
        listOf(
            "--add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.comp=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.main=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.model=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.processing=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED",
            "--add-opens=jdk.compiler/com.sun.tools.javac.comp=ALL-UNNAMED",
        )
}

// ./gradlew spotlessCheck | spotlessApply. Not part of installDist, so not of build.sh.
spotless {
    java {
        target("src/*/java/**/*.java")
        palantirJavaFormat()
        removeUnusedImports()
    }
    kotlinGradle {
        ktlint()
    }
}
