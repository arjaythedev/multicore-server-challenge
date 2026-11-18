#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/bin"

if [ -n "${CIDER_BIN:-}" ] || [ -n "${CIDER_LIB:-}" ]; then
  if [ -z "${CIDER_BIN:-}" ] || [ -z "${CIDER_LIB:-}" ]; then
    echo "Both CIDER_BIN and CIDER_LIB must be set when overriding the compiler." >&2
    exit 1
  fi
elif [ -x "/opt/cider/build/cider" ]; then
  CIDER_BIN="/opt/cider/build/cider"
  CIDER_LIB="/opt/cider/modules"
else
  echo "Cider compiler not found: install it with install.sh, or set CIDER_BIN and CIDER_LIB." >&2
  exit 1
fi

if [ ! -x "$CIDER_BIN" ]; then
  echo "Cider compiler is not executable: $CIDER_BIN" >&2
  exit 1
fi
if [ ! -d "$CIDER_LIB" ]; then
  echo "Cider library directory not found: $CIDER_LIB" >&2
  exit 1
fi
export CIDER_LIB

echo "== [Cider] Compiling modules with $CIDER_BIN..."

MODULES=(
  "sys"
  "uring"
  "http"
  "json"
  "sha256"
  "bcrypt_tables"
  "bcrypt"
  "pg"
  "router"
  "main"
)

for mod in "${MODULES[@]}"; do
  echo "   Compiling src/${mod}.cid..."
  "$CIDER_BIN" compile -c --interface-dir "$DIR/src" --no-entry "$DIR/src/${mod}.cid" -o "$DIR/src/${mod}.o"
done

echo "== [Link] Linking bin/conduit with libpq..."
gcc -Wl,--defsym=main=main__main "$DIR"/src/*.o -lpq -lcrypt -o "$DIR/bin/conduit"

echo "== Build complete: $DIR/bin/conduit"
