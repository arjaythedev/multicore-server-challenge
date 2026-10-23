#!/usr/bin/env bash
# Builds the server as a normal user. The generated binary is bin/conduit.
set -euo pipefail
cd "$(dirname "$0")"
NIM=${NIM:-/opt/nim/bin/nim}
[ -x "$NIM" ] || NIM=nim
mkdir -p bin
"$NIM" c -d:release --opt:speed --mm:arc --threads:off \
  --hints:off --warnings:off \
  --passL:"-lpq -lcrypt -lcrypto -pthread" \
  -o:bin/conduit src/main.nim
