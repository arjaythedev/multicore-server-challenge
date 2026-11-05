#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/cargo/bin/cargo ]; then
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" PATH="/usr/local/cargo/bin:$PATH"
  CARGO="/usr/local/cargo/bin/cargo"
  RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}" "$CARGO" +1.94.0 build --release --locked
else
  RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}" cargo build --release --locked
fi
