#!/usr/bin/env bash
# Runs once as root on clean Ubuntu 24.04 LTS (Noble Numbat).
# Pinned toolchain installer for rust-uring-rishindra2005.
set -euo pipefail

PINNED_RUST_VERSION="${PINNED_RUST_VERSION:-1.97.1}"

echo "=== [install.sh] Installing toolchain dependencies on $(uname -m) ==="
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -y -q \
    build-essential \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    bc \
    linux-tools-common \
    linux-tools-generic || true

# 1. Install pinned Rust toolchain via rustup into /usr/local
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo

if [ ! -x "/usr/local/cargo/bin/rustc" ]; then
    echo "=== [install.sh] Installing rustc ${PINNED_RUST_VERSION} ==="
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
        --profile minimal \
        --default-toolchain "${PINNED_RUST_VERSION}" \
        --no-modify-path
fi

export PATH="/usr/local/cargo/bin:$PATH"
rustup default "${PINNED_RUST_VERSION}" || true
rustup component add llvm-tools-preview || true

RUSTC_BIN="/usr/local/cargo/bin/rustc"
echo "Active rustc: $($RUSTC_BIN --version)"

# Determine LLVM major version from rustc
LLVM_MAJOR="$($RUSTC_BIN -vV | grep -i 'llvm version' | awk '{print $3}' | cut -d'.' -f1)"
echo "Target matching LLVM major version: ${LLVM_MAJOR}"

# 2. Add apt.llvm.org repository for Ubuntu 24.04 (noble) with pinned key
echo "=== [install.sh] Adding apt.llvm.org repository for LLVM ${LLVM_MAJOR} ==="
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/llvm.gpg ]; then
    wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /etc/apt/keyrings/llvm.gpg
fi

CODENAME="noble"
echo "deb [signed-by=/etc/apt/keyrings/llvm.gpg] http://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-${LLVM_MAJOR} main" > /etc/apt/sources.list.d/llvm.list

apt-get update -q

# 3. Install matching clang, lld, llvm-tools, and optional bolt
CLANG_PKG="clang-${LLVM_MAJOR}"
LLD_PKG="lld-${LLVM_MAJOR}"
TOOLS_PKG="llvm-${LLVM_MAJOR}-tools"

echo "=== [install.sh] Installing ${CLANG_PKG}, ${LLD_PKG}, ${TOOLS_PKG} ==="
apt-get install -y -q "${CLANG_PKG}" "${LLD_PKG}" "${TOOLS_PKG}" llvm-bolt || apt-get install -y -q "${CLANG_PKG}" "${LLD_PKG}" "${TOOLS_PKG}" || true

# Ensure convenient symlinks in /usr/local/bin
if [ -x "/usr/bin/clang-${LLVM_MAJOR}" ]; then
    ln -sf "/usr/bin/clang-${LLVM_MAJOR}" /usr/local/bin/clang
fi
if [ -x "/usr/bin/ld.lld-${LLVM_MAJOR}" ]; then
    ln -sf "/usr/bin/ld.lld-${LLVM_MAJOR}" /usr/local/bin/ld.lld
    ln -sf "/usr/bin/ld.lld-${LLVM_MAJOR}" /usr/local/bin/lld
fi
if [ -x "/usr/bin/llvm-profdata-${LLVM_MAJOR}" ]; then
    ln -sf "/usr/bin/llvm-profdata-${LLVM_MAJOR}" /usr/local/bin/llvm-profdata
fi

chmod -R a+rX /usr/local/rustup /usr/local/cargo

echo "=== [install.sh] Complete: $($RUSTC_BIN --version), clang $(clang --version 2>&1 | head -n 1) ==="
