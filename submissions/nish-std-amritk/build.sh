#!/usr/bin/env bash
# Builds the server as a normal user -> bin/conduit, with the compiler and
# LLVM install.sh put in place (nish 0.29.0, clang-18). The program has no
# other dependency: everything it imports is Nish's standard library.
set -euo pipefail
cd "$(dirname "$0")"
NISH="${NISH:-/opt/nish/bin/nish}"
[ -x "$NISH" ] || NISH=nish   # local development: nish on PATH
export CC="${CC:-clang-18}"
mkdir -p bin build
"$NISH" src/main.ts --deny-retention -o build/ --link bin/conduit
