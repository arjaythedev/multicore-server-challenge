#!/usr/bin/env bash
# Builds the release binary as a normal user -> target/release/conduit. Built on the box itself, so target-cpu=native
# picks up the box's SHA-NI/AVX2 for ring's HMAC and memchr.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/cargo/bin/cargo ]; then
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME="$HOME/.cargo"; CARGO=/usr/local/cargo/bin/cargo
else
  CARGO=cargo
fi
RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=native" "$CARGO" build --release --locked
