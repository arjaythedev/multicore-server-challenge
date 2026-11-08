#!/usr/bin/env bash
# Builds the release binary as a normal user -> target/release/conduit. Dependencies are pinned by Cargo.lock.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/cargo/bin/cargo ]; then
  # The registry goes to ~/.cargo (writable); rustc comes from install.sh's toolchain, which must be on PATH
  # because cargo finds rustc through it.
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME="$HOME/.cargo" PATH="/usr/local/cargo/bin:$PATH"
  CARGO=/usr/local/cargo/bin/cargo
elif [ -x "$HOME/.cargo/bin/cargo" ]; then
  # User-local fallback for development hosts where the installer cannot use apt or /usr/local.
  export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  export PATH="$CARGO_HOME/bin:$PATH"
  CARGO="$CARGO_HOME/bin/cargo"
else
  CARGO=cargo   # local development: cargo on PATH
fi
# The benchmark builds and runs on the same x86-64 box, so native instructions are valid and
# remove generic CPU dispatch from the HTTP/JSON hot path. Keep caller flags if supplied.
export RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=native"
"$CARGO" build --release --locked
