#!/usr/bin/env bash
# Builds the release binary as a normal user -> target/release/conduit. Cargo's registry goes to ~/.cargo.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/cargo/bin/cargo ]; then
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME="$HOME/.cargo" PATH="/usr/local/cargo/bin:$PATH"; CARGO=/usr/local/cargo/bin/cargo
else
  CARGO=cargo
fi
"$CARGO" build --release --locked
