#!/usr/bin/env bash
set -euo pipefail
apt-get update -q && apt-get install -y -q build-essential clang binutils curl ca-certificates
if ! command -v cargo >/dev/null 2>&1; then
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path
  chmod -R a+rX /usr/local/rustup /usr/local/cargo
fi
