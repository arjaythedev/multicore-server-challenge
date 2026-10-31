#!/usr/bin/env bash
# Builds pgengine.so with the pinned Zig toolchain against the Postgres 18 server headers.
#   build.sh            -> zig-out/$NAME.so (NAME defaults to pgengine)
#   build.sh install    -> also installs into $libdir/plugins/ (needs sudo)
#                          (PKGLIBDIR overrides pg_config --pkglibdir, for a box without pg_config)
# The C shim is compiled by `zig cc` in the same build, so there is one toolchain.
set -euo pipefail
cd "$(dirname "$0")"
PG_CONFIG=${PG_CONFIG:-/usr/lib/postgresql/18/bin/pg_config}
INC=${PG_INCLUDE:-$("$PG_CONFIG" --includedir-server)}
ZIG=${ZIG:-zig}
OPT=${OPT:-ReleaseFast}
NAME=${NAME:-pgengine}
mkdir -p zig-out
# Zig 0.17 has no @cImport. translate-c renders the headers (Zig caches the result by input
# hash, so reruns are instant) and the sources import them as the module pg_c.
"$ZIG" translate-c -lc -I "$INC" -I shim shim/pg_imports.h > zig-out/pg_c.zig
MODS=(--dep pg_c -Mroot=src/engine.zig -Mpg_c=zig-out/pg_c.zig)
# The HTTP workers' bcrypt kernels (src/web/bcrypt, vendored from the server), built as the server builds them: for
# x86-64-v3 on their own, plus the same Zig kernel for baseline x86-64 as the fallback.
V3=(-O ReleaseFast -fllvm -fPIC -target x86_64-linux -mcpu=x86_64_v3+fast_bextr -fstrip)
"$ZIG" run src/web/bcrypt/asm_gen.zig -- zig-out/bcrypt_expand0.S
"$ZIG" build-obj zig-out/bcrypt_expand0.S "${V3[@]}" --name bcrypt_expand0 -femit-bin=zig-out/bcrypt_expand0.o
"$ZIG" build-obj src/web/bcrypt/kernels.zig "${V3[@]}" --name bcrypt_kernels -femit-bin=zig-out/bcrypt_kernels.o
"$ZIG" build-obj src/web/bcrypt/kernels_port.zig -O ReleaseFast -fllvm -fPIC -target x86_64-linux -mcpu=x86_64 -fstrip \
  --name bcrypt_port -femit-bin=zig-out/bcrypt_port.o
OBJS=(zig-out/bcrypt_kernels.o zig-out/bcrypt_expand0.o zig-out/bcrypt_port.o)
# -fPIC + -dynamic + -lc: a shared object Postgres can dlopen. Postgres symbols stay undefined
# (resolved against the postgres binary at load); Zig builds shared libs that way by default.
"$ZIG" build-lib -dynamic -fPIC -lc -O "$OPT" --name "$NAME" -femit-bin=zig-out/$NAME.so \
  -I "$INC" -I shim \
  -cflags -O2 -fno-strict-aliasing -fwrapv -Wno-unused-parameter -- shim/pgengine_shim.c shim/http_write.c \
  "${OBJS[@]}" "${MODS[@]}"
echo "built zig-out/$NAME.so ($(stat -c %s zig-out/$NAME.so) bytes)"
if [ "${1:-}" = install ]; then
  DEST="${PKGLIBDIR:-$("$PG_CONFIG" --pkglibdir)}/plugins"
  sudo install -d -m 755 "$DEST"
  sudo install -m 644 zig-out/$NAME.so "$DEST/$NAME.so"
  echo "installed $DEST/$NAME.so"
fi
