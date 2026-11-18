import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("multiplatform") version "2.4.21"
}

// Kotlin/Native build-time knobs, read from the environment (the lab exports a plan line's KEY=VALUE to its build step
// too). Unset means the default shown, which is what the Native submission has always built. DESIGN.md "Kotlin/Native
// specifics" says what each one does. A bad value fails the build here instead of inside the compiler.
//   CONDUIT_GC           pmcs | cms | stwms   -Xbinary=gc=...                 default pmcs (Kotlin/Native's own default: cms)
//   CONDUIT_ALLOCATOR    custom | std         -Xallocator=...                 default: Kotlin/Native's (custom)
//   CONDUIT_INLINE       <n>                  -Xbinary=preCodegenInlineThreshold=<n>   default 40 (0: the inliner is off)
//   CONDUIT_LLVM_INLINE  <n>                  llvmInlineThreshold=<n> in the konan properties   default: 100 (LLVM's own: 250)
//   CONDUIT_BINARY       key=value[,key=value...]   any other -Xbinary options, e.g. gcSchedulerType=aggressive,
//                        gcMarkSingleThreaded=true, gcMutatorsCooperate=false, auxGCThreads=2, concurrentWeakSweep=false,
//                        pagedAllocator=false, fixedBlockPageSize=...
// (noop is not offered as a GC: the heap would grow without bound.)
fun conduitEnv(name: String): String? = System.getenv(name)?.trim()?.takeIf { it.isNotEmpty() }

fun conduitChoice(name: String, allowed: Set<String>): String? = conduitEnv(name)?.also {
    if (it !in allowed) throw GradleException("$name must be one of ${allowed.joinToString(" | ")} (got '$it')")
}

fun conduitNumber(name: String): String? = conduitEnv(name)?.also {
    if (it.toIntOrNull()?.let { n -> n >= 0 } != true) throw GradleException("$name must be a non-negative integer (got '$it')")
}

val nativeGc = conduitChoice("CONDUIT_GC", setOf("pmcs", "cms", "stwms")) ?: "pmcs"
val nativeAllocator = conduitChoice("CONDUIT_ALLOCATOR", setOf("custom", "std"))
val nativeInline = conduitNumber("CONDUIT_INLINE") ?: "40"
val nativeLlvmInline = conduitNumber("CONDUIT_LLVM_INLINE")
val nativeBinaryExtra: List<String> = conduitEnv("CONDUIT_BINARY")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
    ?.onEach { kv ->
        val key = kv.substringBefore('=')
        if ('=' !in kv || key.isEmpty() || kv.substringAfter('=').isEmpty()) {
            throw GradleException("CONDUIT_BINARY entries are key=value (got '$kv')")
        }
        if (key == "gc" || key == "preCodegenInlineThreshold") {
            throw GradleException("CONDUIT_BINARY: set '$key' through CONDUIT_${if (key == "gc") "GC" else "INLINE"}, not here")
        }
    } ?: emptyList()
val nativeBinaryArgs: List<String> = buildList {
    add("-Xbinary=gc=$nativeGc")
    add("-Xbinary=preCodegenInlineThreshold=$nativeInline")
    nativeAllocator?.let { add("-Xallocator=$it") }
    nativeBinaryExtra.forEach { add("-Xbinary=$it") }
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
                // LLVM codegen for the build machine's CPU (= the box: build.sh runs there). build.sh detects the
                // CPU name and its full +/- feature list with Kotlin/Native's own clang (-march=native); the full
                // list matters, a bare CPU name could emit instructions a hypervisor masks (SIGILL). Without the
                // properties: Kotlin/Native's portable default (x86-64, SSE2).
                val cpu = providers.gradleProperty("conduit.targetCpu").orNull?.trim()
                val features = providers.gradleProperty("conduit.targetCpuFeatures").orNull?.trim()
                val konanProperties = buildList {
                    if (!cpu.isNullOrEmpty() && !features.isNullOrEmpty()) {
                        add("targetCpu.linux_x64=$cpu")
                        add("targetCpuFeatures.linux_x64=$features")
                    }
                    nativeLlvmInline?.let { add("llvmInlineThreshold=$it") }
                }
                if (konanProperties.isNotEmpty()) {
                    freeCompilerArgs += "-Xoverride-konan-properties=" + konanProperties.joinToString(";")
                }
                // GC, allocator and the inliner (the Kotlin-level one: "try to inline more aggressively"), see the knobs above
                freeCompilerArgs += nativeBinaryArgs
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

// What the Native link is about to build, in the (quiet) build output: the CPU codegen target and the knobs above.
gradle.taskGraph.whenReady {
    if (hasTask(":linkReleaseExecutableLinuxX64") || hasTask(":linkDebugExecutableLinuxX64")) {
        val cpuName = providers.gradleProperty("conduit.targetCpu").orNull?.trim().takeUnless { it.isNullOrEmpty() }
        logger.quiet(
            "conduit native: codegen cpu ${cpuName ?: "generic x86-64"}; " + nativeBinaryArgs.joinToString(" ") +
                (nativeLlvmInline?.let { "; llvmInlineThreshold=$it" } ?: ""),
        )
    }
}

// build/native/libconduit-bcrypt.so: the C bcrypt kernel for the JVM build, compiled with the system C compiler (gcc
// from install.sh; $CC overrides). -O3 matters (the interleaved lanes rely on unrolling: -O2 costs ~30% more); no -m
// flags (the box's CPU is unknown). Without a compiler the build goes on and the server uses the Kotlin lanes.
// Only the JVM build (installJvm) and jvmTest use it; the Native binary compiles native/ in through cinterop.
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

// build/jvm/conduit.jar + build/jvm/lib/*.jar (kotlin-stdlib) + build/jvm/libconduit-bcrypt.so: the JVM build of the
// same tree (this folder's start.sh runs the Native binary instead)
val installJvm by tasks.registering(Copy::class) {
    val jar = tasks.named("jvmJar")
    dependsOn(jar)
    from(jar)
    from(bcryptLib)
    from(configurations.named("jvmRuntimeClasspath")) { into("lib") }
    into(layout.buildDirectory.dir("jvm"))
    rename("conduit-jvm.jar", "conduit.jar")
}
