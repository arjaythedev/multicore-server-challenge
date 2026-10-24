#!/usr/bin/env bash
# Builds the Kotlin/Native server, build/bin/linuxX64/releaseExecutable/conduit.kexe, as a normal user. Idempotent.
# Gradle (pinned, checksummed wrapper) runs on the JDK from install.sh and downloads the Kotlin/Native toolchain
# (compiler + LLVM) itself; the first build takes several minutes. cinterop compiles native/ (the vendored Openwall
# bcrypt core) into the binary with that toolchain's clang, so no system C compiler is needed.
#
# Codegen targets this machine's CPU (the box builds what it runs): Kotlin/Native's clang reports the CPU name and
# its full +/- feature list for -march=native, passed to the compiler via build.gradle.kts. If that fails, the
# binary is built for Kotlin/Native's portable x86-64 default.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then export JAVA_HOME=/opt/jdk; fi

# the cinterop step makes Gradle fetch the Kotlin/Native toolchain (its clang included) on a first build
./gradlew --no-daemon -q cinteropBcryptLinuxX64

cpu_args=()
detect_cpu() {
    local clang out cpu feat
    for clang in "${KONAN_DATA_DIR:-$HOME/.konan}"/dependencies/llvm-*-essentials-*/bin/clang; do
        [ -x "$clang" ] || continue
        out=$("$clang" -march=native -### -c -x c /dev/null -o /dev/null 2>&1) || continue
        cpu=$(printf '%s' "$out" | grep -o '"-target-cpu" "[^"]*"' | head -1 | cut -d'"' -f4)
        feat=$(printf '%s' "$out" | grep -o '"-target-feature" "[^"]*"' | cut -d'"' -f4 | paste -sd, -)
        if [ -n "$cpu" ] && [ -n "$feat" ] && [ "$cpu" != x86-64 ]; then
            echo "build.sh: codegen for this CPU: $cpu, $(tr ',' '\n' <<<"$feat" | grep -c '^+') features on (via $clang)"
            cpu_args=("-Pconduit.targetCpu=$cpu" "-Pconduit.targetCpuFeatures=$feat")
            return 0
        fi
    done
    return 1
}
if [ "${CONDUIT_GENERIC_CPU:-0}" = 1 ] || ! detect_cpu; then
    echo "build.sh: codegen for generic x86-64 (CPU detection off or failed)"
fi

./gradlew --no-daemon -q linkReleaseExecutableLinuxX64 "${cpu_args[@]}"
ls -l build/bin/linuxX64/releaseExecutable/conduit.kexe
