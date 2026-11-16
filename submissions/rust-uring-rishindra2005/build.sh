#!/usr/bin/env bash
# Builds the server from source.
# Works cleanly under clean environment: env -i ... bash build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export HOME="${HOME:-/home/$(whoami)}"
export USER="${USER:-$(whoami)}"
export LANG="${LANG:-C.UTF-8}"

if [ -d "/usr/local/rustup" ]; then
    export RUSTUP_HOME="/usr/local/rustup"
elif [ -d "$HOME/.rustup" ]; then
    export RUSTUP_HOME="$HOME/.rustup"
fi

export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"

if [ -x "/usr/local/cargo/bin/cargo" ]; then
    export PATH="/usr/local/cargo/bin:/usr/local/bin:$PATH"
    CARGO="/usr/local/cargo/bin/cargo"
elif [ -x "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"
    CARGO="$HOME/.cargo/bin/cargo"
elif command -v cargo >/dev/null 2>&1; then
    CARGO="$(command -v cargo)"
else
    echo "ERROR: cargo not found in PATH" >&2
    exit 1
fi

RUSTC_BIN="$(command -v rustc)"
LLVM_MAJOR="$($RUSTC_BIN -vV | grep -i 'llvm version' | awk '{print $3}' | cut -d'.' -f1)"

CLANG_BIN="clang"
LLD_ARG="-fuse-ld=lld"
PROFDATA_BIN="llvm-profdata"

command -v "clang-${LLVM_MAJOR}" >/dev/null 2>&1 && CLANG_BIN="clang-${LLVM_MAJOR}"
command -v "ld.lld-${LLVM_MAJOR}" >/dev/null 2>&1 && LLD_ARG="-fuse-ld=/usr/bin/ld.lld-${LLVM_MAJOR}"
command -v "llvm-profdata-${LLVM_MAJOR}" >/dev/null 2>&1 && PROFDATA_BIN="llvm-profdata-${LLVM_MAJOR}"

BASE_FLAGS="-C target-cpu=native -C codegen-units=1 -C panic=abort -C linker-plugin-lto -C linker=${CLANG_BIN} -C link-arg=${LLD_ARG} -C link-arg=-Wl,--emit-relocs"
PGO_DIR="/tmp/pgo-$(id -u)-build"
rm -rf "$PGO_DIR" && mkdir -p "$PGO_DIR"

fallback_build() {
    echo "=== [build.sh] WARNING: Advanced optimizations failed; falling back to clean release build ==="
    RUSTFLAGS="-C target-cpu=native -C panic=abort" "$CARGO" build --release
    echo "=== [build.sh] Fallback release build succeeded ==="
    exit 0
}

trap fallback_build ERR

echo "=== [build.sh] Step 1: Building PGO instrumented binary ==="
RUSTFLAGS="-C profile-generate=${PGO_DIR} ${BASE_FLAGS}" "$CARGO" build --release

echo "=== [build.sh] Step 2: Running self-contained training workload ==="
./target/release/rust-uring-rishindra2005 --train

echo "=== [build.sh] Step 3: Merging profile data ==="
"$PROFDATA_BIN" merge -o "${PGO_DIR}/merged.profdata" "${PGO_DIR}"

echo "=== [build.sh] Step 4: Rebuilding with profile-use ==="
RUSTFLAGS="-C profile-use=${PGO_DIR}/merged.profdata ${BASE_FLAGS}" "$CARGO" build --release

# Optional BOLT step
if command -v llvm-bolt >/dev/null 2>&1; then
    echo "=== [build.sh] Optional Step 5: Applying LLVM-BOLT reordering ==="
    BOLT_FDATA="/tmp/bolt-$(id -u).fdata"
    BIN="target/release/rust-uring-rishindra2005"
    if llvm-bolt "$BIN" -instrument --instrumentation-file="$BOLT_FDATA" -o "${BIN}.inst" 2>/dev/null; then
        "${BIN}.inst" --train >/dev/null 2>&1 || true
        if [ -s "$BOLT_FDATA" ]; then
            if llvm-bolt "$BIN" -data="$BOLT_FDATA" \
                -reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions -split-all-cold \
                -o "${BIN}.bolt" 2>/dev/null; then
                mv "${BIN}.bolt" "$BIN"
                echo "=== [build.sh] BOLT layout optimization applied successfully ==="
            fi
        fi
        rm -f "${BIN}.inst" "$BOLT_FDATA"
    fi
fi

rm -rf "$PGO_DIR"
echo "=== [build.sh] Build completed successfully ==="
