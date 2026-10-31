#!/usr/bin/env bash
# Builds bin/conduit as a normal user. One compiler call, no build system,
# no downloads, no external deps beyond apt-installed liburing/libcrypt.
# Exits 0 with a note even while src/ is still empty (pre-implementation).
set -euo pipefail
cd "$(dirname "$0")"

CC="${CC:-gcc}"
sources=()

for f in src/*.c; do
  [ -e "$f" ] && sources+=("$f")
done

if [ ${#sources[@]} -eq 0 ]; then
  echo "build.sh: no sources in src/ yet — nothing to compile, exiting 0"
  exit 0
fi

# Canonical perf flags (-O3, native arch): override ARCH_FLAGS for portable builds;
# PROFILE=1 keeps frame pointers for profiling, default is -fomit-frame-pointer.
# -luring: io_uring event loop. -lcrypt: bcrypt hash formats we don't
# implement ourselves. -lm: math helpers.
ARCH_FLAGS="${ARCH_FLAGS:--march=native}"
if [ "${PROFILE:-0}" = "1" ]; then FP_FLAG="-fno-omit-frame-pointer"; else FP_FLAG="-fomit-frame-pointer"; fi
mkdir -p bin
"$CC" -std=gnu11 -O3 $ARCH_FLAGS -flto -fstrict-aliasing "$FP_FLAG" -pthread -Wall -Wextra -Wno-unused-parameter \
  -o bin/conduit "${sources[@]}" -luring -lcrypt -lm
echo "built bin/conduit ($("$CC" --version | head -1))"
