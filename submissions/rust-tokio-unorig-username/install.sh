#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C toolchain (for the linker) and Rust 1.99.0 via rustup in
# /usr/local, readable by every user. rustup-init is fetched by version and checked against its sha256.
set -euo pipefail
apt-get update -q && apt-get install -y -q build-essential curl ca-certificates
RUSTUP_VERSION=1.28.2
ARCH="$(uname -m)-unknown-linux-gnu"
curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/$ARCH/rustup-init"
curl -fsSLo /tmp/rustup-init.sha256 "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/$ARCH/rustup-init.sha256"
case "$ARCH" in
  x86_64-*)  SHA=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c ;;
  aarch64-*) SHA=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c ;;
esac
echo "$SHA  /tmp/rustup-init" | sha256sum -c -
chmod +x /tmp/rustup-init
export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
/tmp/rustup-init -y --profile minimal --default-toolchain 1.99.0 --no-modify-path
rm /tmp/rustup-init /tmp/rustup-init.sha256
chmod -R a+rX /usr/local/rustup /usr/local/cargo
/usr/local/cargo/bin/rustc --version
