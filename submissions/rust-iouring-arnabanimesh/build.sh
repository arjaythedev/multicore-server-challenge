#!/usr/bin/env bash
# Builds the server as a normal user.
set -euo pipefail
cd "$(dirname "$0")"

# Use the root-installed toolchain directly (no rustup proxy, no RUSTUP_HOME needed).
TC_BIN="$(ls -d /opt/rustup/toolchains/*/bin 2>/dev/null | head -n1 || true)"
if [ -n "${TC_BIN}" ]; then
  export PATH="${TC_BIN}:${PATH}"
fi
export CARGO_TERM_COLOR=never

if [ -f Cargo.lock ]; then
  cargo build --release --locked
else
  cargo build --release
fi