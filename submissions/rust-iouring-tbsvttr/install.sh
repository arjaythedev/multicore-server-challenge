#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential curl ca-certificates

RUST_VERSION="1.94.0"
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
export PATH="/usr/local/cargo/bin:$PATH"

if [ ! -x /usr/local/cargo/bin/rustup ]; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}" --no-modify-path
fi
/usr/local/cargo/bin/rustup toolchain install "${RUST_VERSION}" --profile minimal
/usr/local/cargo/bin/rustup default "${RUST_VERSION}"
chmod -R a+rX /usr/local/rustup /usr/local/cargo
/usr/local/cargo/bin/rustc +"${RUST_VERSION}" --version
