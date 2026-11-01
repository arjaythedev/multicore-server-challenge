#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C linker (cc, from build-essential) and Rust 1.99.0 via rustup in
# /usr/local, readable by every user. The server itself has no third-party crates.
set -euo pipefail
apt-get update -q && apt-get install -y -q build-essential curl ca-certificates
export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.99.0 --no-modify-path
chmod -R a+rX /usr/local/rustup /usr/local/cargo
/usr/local/cargo/bin/rustc --version
