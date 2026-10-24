import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("multiplatform") version "2.4.21"
}

kotlin {
    jvm {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_25) }
    }
    linuxX64 {
        // src/nativeInterop/cinterop/bcrypt.def: the C bcrypt kernel (native/), compiled in by Kotlin/Native's clang
        compilations.getByName("main").cinterops.create("bcrypt") {
            includeDirs(project.file("native"))
        }
        binaries {
            executable {
                entryPoint = "conduit.main"
                baseName = "conduit"
                // LLVM codegen for the build machine's CPU (= the box: build.sh runs there). build.sh detects the
                // CPU name and its full +/- feature list with Kotlin/Native's own clang (-march=native); the full
                // list matters, a bare CPU name could emit instructions a hypervisor masks (SIGILL). Without the
                // properties: Kotlin/Native's portable default (x86-64, SSE2).
                val cpu = providers.gradleProperty("conduit.targetCpu").orNull?.trim()
                val features = providers.gradleProperty("conduit.targetCpuFeatures").orNull?.trim()
                if (!cpu.isNullOrEmpty() && !features.isNullOrEmpty()) {
                    freeCompilerArgs += "-Xoverride-konan-properties=" +
                        "targetCpu.linux_x64=$cpu;targetCpuFeatures.linux_x64=$features"
                }
                // Try to inline more aggressively
                freeCompilerArgs += "-Xbinary=preCodegenInlineThreshold=40"
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

tasks.named("cinteropBcryptLinuxX64") { inputs.dir("native") } // the .def #includes these

// build/native/libconduit-bcrypt.so: the C bcrypt kernel for the JVM build, compiled with the system C compiler (gcc
// from install.sh; $CC overrides). -O3 matters (the interleaved lanes rely on unrolling: -O2 costs ~30% more); no -m
// flags (the box's CPU is unknown). Without a compiler the build goes on and the server uses the Kotlin lanes.
val bcryptLib by tasks.registering {
    val src = layout.projectDirectory.dir("native")
    val lib = layout.buildDirectory.file("native/libconduit-bcrypt.so")
    val cc = System.getenv("CC")?.takeIf { it.isNotBlank() } ?: "cc"
    inputs.dir(src)
    inputs.property("cc", cc)
    outputs.file(lib)
    outputs.upToDateWhen { lib.get().asFile.isFile } // retry a failed compile next time
    doLast {
        val out = lib.get().asFile
        out.parentFile.mkdirs()
        out.delete()
        val cmd = listOf(cc, "-O3", "-fPIC", "-shared", "-o", out.path, src.file("conduit-bcrypt.c").asFile.path)
        val rc = try {
            ProcessBuilder(cmd).inheritIO().start().waitFor()
        } catch (e: java.io.IOException) {
            logger.quiet("bcryptLib: $e")
            -1
        }
        if (rc != 0) {
            out.delete()
            logger.quiet("WARNING: could not build ${out.name} ($cc exit $rc); bcrypt will use the pure-Kotlin lanes")
        }
    }
}

tasks.named<Test>("jvmTest") {
    dependsOn(bcryptLib)
    systemProperty("conduit.bcrypt.lib", layout.buildDirectory.file("native/libconduit-bcrypt.so").get().asFile.path)
    jvmArgs("--enable-native-access=ALL-UNNAMED")
}

// build/jvm/conduit.jar + build/jvm/lib/*.jar (kotlin-stdlib) + build/jvm/libconduit-bcrypt.so: what start.sh runs
val installJvm by tasks.registering(Copy::class) {
    val jar = tasks.named("jvmJar")
    dependsOn(jar)
    from(jar)
    from(bcryptLib)
    from(configurations.named("jvmRuntimeClasspath")) { into("lib") }
    into(layout.buildDirectory.dir("jvm"))
    rename("conduit-jvm.jar", "conduit.jar")
}
