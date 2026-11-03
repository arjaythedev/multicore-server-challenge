#!/usr/bin/env bash
# Builds the server as a normal user -> bin/conduit, with the compiler and
# LLVM install.sh put in place (nish 0.32.0, clang-18). The program has no
# other dependency: everything it imports is Nish's standard library.
#
# It is built for the machine it is built on, as the challenge builds it: for
# x86-64-v3 (AVX2, BMI2) when /proc/cpuinfo lists every feature of it, and
# baseline x86-64 otherwise. Then bin/bcrypt-width times bcrypt's batch widths
# on this machine (about a second) and keeps the fastest in bin/bcrypt-width
# for start.sh; a run that fails leaves the server's default.
set -euo pipefail
cd "$(dirname "$0")"
NISH="${NISH:-/opt/nish/bin/nish}"
[ -x "$NISH" ] || NISH=nish   # local development: nish on PATH
export CC="${CC:-clang-18}"
mkdir -p bin build
CPU=()
flags=" $(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2) "
v3=1
for f in avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do
  case "$flags" in *" $f "*) ;; *) v3=0 ;; esac
done
[ "$v3" = 1 ] && CPU=(--cpu x86-64-v3)
echo "build: ${CPU[*]:-baseline x86-64}"
"$NISH" src/main.ts --deny-retention "${CPU[@]}" -o build/ --link bin/conduit
rm -f bin/bcrypt-width.txt
if "$NISH" src/bcrypt-width.ts --deny-retention "${CPU[@]}" -o build/width/ --link bin/bcrypt-width; then
  w="$(bin/bcrypt-width || true)"
  case "$w" in [1-6]) echo "$w" > bin/bcrypt-width.txt; echo "build: bcrypt runs $w lanes a call here" ;; esac
fi
