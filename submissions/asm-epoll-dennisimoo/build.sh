#!/usr/bin/env bash
# Assembles every src/*.s with GNU as (Intel syntax, set per-file by `.intel_syntax noprefix`) and links them
# statically with ld into ./conduit. No libc, no CRT: the entry point is _start in main.s and every external
# call is a raw Linux syscall. Builds as a normal user.
set -euo pipefail
cd "$(dirname "$0")"

SRC=src
OUT=build
BIN=conduit
mkdir -p "$OUT"

# Deterministic link order does not matter (ld resolves globals across all objects), but list main first so the
# entry object is obvious. .include resolves relative to -I, so assemble with the source dir on the include path.
objs=()
for s in "$SRC"/main.s "$SRC"/rt.s "$SRC"/cpu.s "$SRC"/crypto.s "$SRC"/bcrypt.s "$SRC"/pg.s "$SRC"/http.s \
         "$SRC"/json.s "$SRC"/server.s "$SRC"/pgio.s "$SRC"/api.s "$SRC"/render.s "$SRC"/sql.s "$SRC"/bcq.s \
         "$SRC"/writer.s "$SRC"/readr.s "$SRC"/readb.s \
         "$SRC"/egress.s "$SRC"/gzip.s; do
  o="$OUT/$(basename "${s%.s}").o"
  as --64 -I "$SRC" -o "$o" "$s"
  objs+=("$o")
done

# -static, no dynamic linker, no standard libs. _start is our entry.
ld -static -nostdlib -o "$BIN" -e _start "${objs[@]}"
echo "built ./$BIN"
