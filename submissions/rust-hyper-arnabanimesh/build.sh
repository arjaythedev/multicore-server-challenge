#!/usr/bin/env bash
# Builds the server as a normal user (downloads the crates listed in Cargo.lock).
set -euo pipefail
cd "$(dirname "$0")"

# install.sh puts the pinned toolchain in /opt/rust; on a dev machine fall back to whatever cargo is on PATH.
if [ -x /opt/rust/bin/cargo ]; then
  export PATH="/opt/rust/bin:$PATH"
fi
export CARGO_TERM_COLOR=never
# Built on the machine it runs on, so use all of its instruction set.
export RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=native"

if [ -f Cargo.lock ]; then
  cargo build --release --locked
else
  echo "warning: no Cargo.lock; run 'cargo generate-lockfile' once and commit it to pin the dependencies" >&2
  cargo build --release
fi