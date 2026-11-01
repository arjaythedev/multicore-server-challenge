#!/usr/bin/env bash
# Copies the shared Kotlin Multiplatform sources of this (canonical) submission into a variant submission folder,
# e.g. the Kotlin/Native one on its own branch/worktree. Each variant keeps its own install.sh, build.sh, start.sh
# and README.md; everything else (sources, Gradle build, DESIGN.md, tools) is mirrored exactly (deletions too).
#   tools/sync-variant.sh <path to the variant's submission folder>
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DST="${1:?usage: tools/sync-variant.sh <variant submission folder>}"
mkdir -p "$DST"
KEEP=(install.sh build.sh start.sh README.md build .gradle .kotlin)
args=(); for k in "${KEEP[@]}"; do args+=(! -name "$k"); done
find "$DST" -mindepth 1 -maxdepth 1 "${args[@]}" -exec rm -rf {} +
(cd "$SRC" && tar --exclude=./install.sh --exclude=./build.sh --exclude=./start.sh --exclude=./README.md \
  --exclude=./lab --exclude=./build --exclude=./.gradle --exclude=./.kotlin -cf - .) | (cd "$DST" && tar -xf -)
echo "synced $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo '?') sources -> $DST"
