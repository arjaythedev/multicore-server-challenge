#!/usr/bin/env bash
# Builds the B entrypoint and links it to the hand-written support runtime.
set -euo pipefail
cd "$(dirname "$0")"
CC="${CC:-gcc}"
mkdir -p bin .build
make -C bcause CC="$CC" >/dev/null
# BCause emits a.s for -S. Compile that B-generated assembly with the same host toolchain.
./bcause/bcause -S main.b >/dev/null
# BCause assumes its entry function is called from its own `_start`, where the
# incoming stack has the SysV call alignment. The generated `main` is linked
# with the host C runtime below, whose startup call has the opposite alignment;
# this empty B frame does not need the compiler's reserved word. The router now
# has its own B frames, so remove the adjustment specifically inside `main`.
awk '
  /^main:$/ { in_main = 1 }
  in_main && /^  sub \$8, %rsp$/ && !removed { removed = 1; next }
  in_main && /^\.L\.return\.main:$/ { in_main = 0 }
  { print }
' a.s > a.s.fixed
mv a.s.fixed a.s
"$CC" -c a.s -o .build/bmain.o
objs=()
for src in src/*.c; do
  name="$(basename "$src" .c)"
  obj=".build/${name}.o"
  "$CC" -std=gnu11 -O2 -march=native -pthread -Wall -Wextra -Wno-unused-parameter \
    -Dmain=c_server_main -c "$src" -o "$obj"
  objs+=("$obj")
done
# Let the host C runtime own process startup.  BCause's bundled libb.a supplies a
# raw `_start` that skips glibc initialization; that is unsafe for the pthread and
# libc code used by the support runtime and can crash on the first request.
"$CC" -o bin/conduit .build/bmain.o "${objs[@]}" \
  -luring -lcrypt -lm -lpthread
printf 'built B entrypoint with %s\n' "$($CC --version | head -1)"
