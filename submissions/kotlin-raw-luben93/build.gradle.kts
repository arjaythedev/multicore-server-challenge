import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("multiplatform") version "2.4.21"
}

kotlin {
    jvm {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_25) }
    }
    linuxX64 {
        binaries {
            executable {
                entryPoint = "conduit.main"
                baseName = "conduit"
            }
        }
    }

    compilerOptions {
        optIn.addAll(
            "kotlin.concurrent.atomics.ExperimentalAtomicApi",
            "kotlin.experimental.ExperimentalNativeApi",
            "kotlinx.cinterop.ExperimentalForeignApi",
        )
        freeCompilerArgs.add("-Xexpect-actual-classes")
    }

    sourceSets {
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}

// build/jvm/conduit.jar + build/jvm/lib/*.jar (kotlin-stdlib): what start.sh runs
val installJvm by tasks.registering(Copy::class) {
    val jar = tasks.named("jvmJar")
    dependsOn(jar)
    from(jar)
    from(configurations.named("jvmRuntimeClasspath")) { into("lib") }
    into(layout.buildDirectory.dir("jvm"))
    rename("conduit-jvm.jar", "conduit.jar")
}
