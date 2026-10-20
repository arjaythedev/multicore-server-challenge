#!/usr/bin/env bash
# Builds the release binary as a normal user -> target/release/conduit-urus.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/cargo/bin/cargo ]; then
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME="$HOME/.cargo"; CARGO=/usr/local/cargo/bin/cargo
else
  CARGO=cargo
fi
export CARGO_NET_GIT_FETCH_WITH_CLI=true
"$CARGO" build --release --locked
