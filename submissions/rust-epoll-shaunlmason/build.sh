#!/usr/bin/env bash
# Builds the release binary as a normal user -> target/release/conduit. Dependencies are pinned by Cargo.lock.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/cargo/bin/cargo ]; then
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME="$HOME/.cargo" PATH="/usr/local/cargo/bin:$PATH"
  CARGO=/usr/local/cargo/bin/cargo
else
  CARGO=cargo
fi
RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}" "$CARGO" build --release --locked
