#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: rustup with Rust 1.97.1 in /usr/local (readable by every user).
set -euo pipefail
apt-get update -q && apt-get install -y -q build-essential curl ca-certificates
export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.97.1 --no-modify-path
chmod -R a+rX /usr/local/rustup /usr/local/cargo
/usr/local/cargo/bin/rustc --version
