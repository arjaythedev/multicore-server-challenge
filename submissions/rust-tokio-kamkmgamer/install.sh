#!/usr/bin/env bash
# Runs once on the benchmark box: a C toolchain (native bcrypt is built from C source) and Rust 1.99.0.
# The challenge invokes this as root on Ubuntu; the user-local branch keeps the same script usable in
# restricted development containers where apt and /usr/local are unavailable.
set -euo pipefail
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -q
  apt-get install -y -q build-essential curl ca-certificates
fi
if [ "$(id -u)" -eq 0 ]; then
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
else
  export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
fi
curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.99.0 --no-modify-path
if [ "$(id -u)" -eq 0 ]; then
  chmod -R a+rX "$RUSTUP_HOME" "$CARGO_HOME"
fi
"$CARGO_HOME/bin/rustc" --version
