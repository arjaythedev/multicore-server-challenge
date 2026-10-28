#!/usr/bin/env bash
# Builds the release binary as a normal user -> target/release/conduit. Versions are pinned by Cargo.lock.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/cargo/bin/cargo ]; then
  # install.sh's toolchain; the crate registry goes to the (writable) ~/.cargo
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME="$HOME/.cargo" PATH="/usr/local/cargo/bin:$PATH"
fi
cargo build --release --locked
