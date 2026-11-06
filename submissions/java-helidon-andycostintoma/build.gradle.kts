plugins {
    application
    id("com.diffplug.spotless") version "8.11.0"
}

group = "conduit"
version = "0.1.0"

repositories {
    mavenCentral()
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(25)
    }
}

spotless {
    java {
        target("src/main/java/**/*.java", "src/test/java/**/*.java")
        targetExclude("src/main/java/conduit/generated/postgres/jooq/**/*.java")
        eclipse("4.41").configProperties(
            """
            org.eclipse.jdt.core.javaFormatter=org.eclipse.jdt.core.defaultJavaFormatter
            org.eclipse.jdt.core.compiler.source=25
            org.eclipse.jdt.core.compiler.compliance=25
            org.eclipse.jdt.core.compiler.codegen.targetPlatform=25
            org.eclipse.jdt.core.formatter.tabulation.char=space
            org.eclipse.jdt.core.formatter.tabulation.size=4
            org.eclipse.jdt.core.formatter.indentation.size=4
            org.eclipse.jdt.core.formatter.continuation_indentation=1
            org.eclipse.jdt.core.formatter.lineSplit=100
            # Force one record component per line, indented by one level.
            org.eclipse.jdt.core.formatter.alignment_for_record_components=53
            org.eclipse.jdt.core.formatter.parentheses_positions_in_record_declaration=separate_lines_if_not_empty
            org.eclipse.jdt.core.formatter.brace_position_for_record_declaration=end_of_line
            """.trimIndent()
        )
    }
}

val jooqCodegen = configurations.create("jooqCodegen")

dependencies {
    implementation(platform("io.helidon:helidon-dependencies:4.5.6"))
    implementation(platform("com.fasterxml.jackson:jackson-bom:2.22.4"))
    implementation("io.helidon.webserver:helidon-webserver")
    implementation("com.fasterxml.jackson.core:jackson-databind")
    implementation("org.jooq:jooq:3.21.9")
    implementation("org.postgresql:postgresql:42.7.14")
    implementation("com.zaxxer:HikariCP:7.1.0")
    implementation("com.auth0:java-jwt:4.6.2")
    implementation("at.favre.lib:bcrypt:0.10.2")
    compileOnly("jakarta.xml.bind:jakarta.xml.bind-api")
    runtimeOnly("org.slf4j:slf4j-jdk14:2.0.17")

    jooqCodegen("org.jooq:jooq-codegen:3.21.9")
    jooqCodegen("org.postgresql:postgresql:42.7.14")
    jooqCodegen("org.testcontainers:testcontainers-postgresql:2.0.5")
    jooqCodegen("org.testcontainers:testcontainers-jdbc:2.0.5")
    jooqCodegen("org.slf4j:slf4j-jdk14:2.0.17")

    testImplementation(platform("org.junit:junit-bom:5.12.2"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testImplementation("org.testcontainers:testcontainers-postgresql:2.0.5")
    testImplementation("com.tngtech.archunit:archunit:1.5.1")
    testCompileOnly("jakarta.xml.bind:jakarta.xml.bind-api")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

application {
    mainClass = "conduit.Main"
}

val generatedJooq = layout.projectDirectory.dir("src/main/java/conduit/generated/postgres/jooq")

val generateJooq = tasks.register<JavaExec>("generateJooq") {
    description = "Regenerates checked-in jOOQ sources using a disposable PostgreSQL Docker container."
    group = "code generation"
    classpath = jooqCodegen
    mainClass = "org.jooq.codegen.GenerationTool"
    args("jooq-codegen.xml")
    workingDir(projectDir)
    inputs.file("../../schema.sql")
    inputs.file("jooq-codegen.xml")
    outputs.dir(generatedJooq)
}

tasks.compileJava {
    mustRunAfter(generateJooq)
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
}

tasks.test {
    exclude("**/*IT.class")
}

tasks.processTestResources {
    from("../../schema.sql")
}

val integrationTest = tasks.register<Test>("integrationTest") {
    description = "Runs HTTP/database tests against a disposable Docker PostgreSQL instance."
    group = "verification"
    testClassesDirs = sourceSets.test.get().output.classesDirs
    classpath = sourceSets.test.get().runtimeClasspath
    include("**/*IT.class")
    outputs.upToDateWhen { false }
}

tasks.check {
    dependsOn(integrationTest)
}
