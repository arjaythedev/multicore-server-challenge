#!/usr/bin/env bash
# Builds the release binary as a normal user -> target/release/conduit. Dependencies are pinned by Cargo.lock.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/cargo/bin/cargo ]; then
  # The registry goes to ~/.cargo (writable); rustc comes from install.sh's toolchain, which must be on PATH
  # because cargo finds rustc through it.
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME="$HOME/.cargo" PATH="/usr/local/cargo/bin:$PATH"
  CARGO=/usr/local/cargo/bin/cargo
else
  CARGO=cargo   # local development: cargo on PATH
fi
"$CARGO" build --release --locked
