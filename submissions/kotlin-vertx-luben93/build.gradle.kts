import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("multiplatform") version "2.4.21"
}

kotlin {
    jvm {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_25)
            // no Intrinsics.checkNotNull* calls on every parameter, call result and receiver (all Kotlin callers)
            freeCompilerArgs.addAll("-Xno-param-assertions", "-Xno-call-assertions", "-Xno-receiver-assertions")
        }
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
        // HTTP_IO=netty / netty-http (lab A/B against our own epoll loops): Netty 4.2's native epoll transport and
        // its HTTP/1.1 decoder. Unused by default.
        jvmMain.dependencies {
            implementation("io.netty:netty-transport-native-epoll:4.2.19.Final:linux-x86_64")
            implementation("io.netty:netty-codec-http:4.2.19.Final")
            // DB_DRIVER=vertx: the Vert.x reactive Postgres client (5.2.1 is built on Netty 4.2.19, the same Netty)
            implementation("io.vertx:vertx-pg-client:5.2.1")
            // vertx-core wants jackson-core 2.21.7; 2.21.4 (a patch release older) is the one in the lab's offline cache
            implementation("com.fasterxml.jackson.core:jackson-core") { version { strictly("2.21.4") } }
            // NETTY_URING=1 at build time (lab experiment): Netty's io_uring transport too, for NETTY_TRANSPORT=io_uring
            if (providers.environmentVariable("NETTY_URING").orNull == "1") {
                implementation("io.netty:netty-transport-native-io_uring:4.2.19.Final:linux-x86_64")
            }
        }
    }
}

tasks.named("cinteropBcryptLinuxX64") { inputs.dir("native") } // the .def #includes these

// build/native/libconduit-bcrypt.so: the C bcrypt kernel for the JVM build, compiled with the system C compiler (gcc
// from install.sh; $CC overrides). -O3 matters (the interleaved lanes rely on unrolling: -O2 costs ~30% more).
// -march=native: build.sh runs on the box, so this is the box's own CPU (BCRYPT_MARCH=generic: portable x86-64).
// Without a compiler the build goes on and the server uses the Kotlin lanes.
val bcryptLib by tasks.registering {
    val src = layout.projectDirectory.dir("native")
    val lib = layout.buildDirectory.file("native/libconduit-bcrypt.so")
    val cc = System.getenv("CC")?.takeIf { it.isNotBlank() } ?: "cc"
    val march = if (System.getenv("BCRYPT_MARCH") == "generic") emptyList() else listOf("-march=native")
    inputs.dir(src)
    inputs.property("cc", cc)
    inputs.property("march", march.joinToString(" "))
    outputs.file(lib)
    outputs.upToDateWhen { lib.get().asFile.isFile } // retry a failed compile next time
    doLast {
        val out = lib.get().asFile
        out.parentFile.mkdirs()
        out.delete()
        val cmd = listOf(cc, "-O3") + march +
            listOf("-fPIC", "-shared", "-o", out.path, src.file("conduit-bcrypt.c").asFile.path)
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
