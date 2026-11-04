#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential curl ca-certificates

export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
if [ ! -x /usr/local/cargo/bin/cargo ]; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.94.0 --no-modify-path || \
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path
fi
chmod -R a+rX /usr/local/rustup /usr/local/cargo
/usr/local/cargo/bin/rustc --version

