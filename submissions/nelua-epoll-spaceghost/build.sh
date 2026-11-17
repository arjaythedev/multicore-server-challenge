#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
APP_IMPL="${APP_IMPL:-nelua}"
MEMORY_IMPL="${MEMORY_IMPL:-nelibc}"
CORE_PROFILE="${CORE_PROFILE:-freestanding}"
BUFFER_CACHE="${BUFFER_CACHE:-auto}"
case "$CORE_PROFILE" in
  host|freestanding) ;;
  *) echo "CORE_PROFILE must be host or freestanding" >&2; exit 1 ;;
esac
case "$MEMORY_IMPL" in
  host|nelibc) ;;
  *) echo "MEMORY_IMPL must be host or nelibc" >&2; exit 1 ;;
esac
case "$APP_IMPL" in
  nelua|c) ;;
  *) echo "APP_IMPL must be c or nelua" >&2; exit 1 ;;
esac
if [ "$BUFFER_CACHE" = auto ]; then
  if [ "$MEMORY_IMPL" = nelibc ]; then BUFFER_CACHE=1; else BUFFER_CACHE=0; fi
fi
case "$BUFFER_CACHE" in
  0|1) ;;
  *) echo 'BUFFER_CACHE must be auto, 0 or 1' >&2; exit 1 ;;
esac
PG_CONFIG="${PG_CONFIG:-pg_config}"
if ! command -v "$PG_CONFIG" >/dev/null 2>&1; then
  echo 'libpq development tools are required; run install.sh or set PG_CONFIG' >&2
  exit 1
fi
mkdir -p build bin
if [ "$APP_IMPL" = nelua ]; then
NELUA_REV=a58450563e2d2ec49bff499865c8b5cfdf6ff81a
NELUA_ROOT="${NELUA_ROOT:-$PWD/.deps/nelua}"
if [ ! -e "$NELUA_ROOT/.git" ]; then
  mkdir -p "$(dirname "$NELUA_ROOT")"
  git clone --no-checkout https://github.com/edubart/nelua-lang.git "$NELUA_ROOT"
  git -C "$NELUA_ROOT" checkout --detach "$NELUA_REV"
fi
if [ "$(git -C "$NELUA_ROOT" rev-parse HEAD)" != "$NELUA_REV" ] ||
   ! git -C "$NELUA_ROOT" diff --quiet HEAD --; then
  echo "Expected unmodified official Nelua at $NELUA_REV" >&2; exit 1
fi
make -C "$NELUA_ROOT" -j"${JOBS:-2}"
# Generate C afresh and link companions explicitly; no compiler binary cache is used.
(cd src && "$NELUA_ROOT/nelua" --cache-dir "$PWD/../build/nelua-cache" --no-cache --release --print-code main.nelua) > build/app.c.tmp
mv build/app.c.tmp build/app.c
python3 tools/export_sql.py --check
APP_SOURCES=(build/app.c)
APP_FLAGS=(-DNC_BUFFER_CACHE="$BUFFER_CACHE")
APP_BINARY=bin/conduit
else
# The C counterpart needs neither the Nelua compiler nor generated application
# code. sql_shared.h is shared statement data, verified by the Nelua build.
APP_SOURCES=(src/app_c.c src/batch_c.c src/serialize_c.c)
APP_FLAGS=(-DNC_APP_C -DNC_BUFFER_CACHE="$BUFFER_CACHE")
APP_BINARY=bin/conduit-c
fi
MEMORY_LIBS=()
CORE_BRIDGE=()
if [ "$MEMORY_IMPL" = nelibc ]; then
  if [ -z "${NELIBC_ROOT:-}" ] && [ -z "${NELIBC_ARCHIVE:-}" ]; then
    python3 tools/bootstrap_nelibc.py --cache "${NELIBC_CACHE:-$PWD/.deps/nelibc-source}" \
      --manifest build/nelibc-source-build.json --jobs "${JOBS:-2}"
    mapfile -t NELIBC_PATHS < <(python3 -c 'import json; x=json.load(open("build/nelibc-source-build.json")); print(x["source"]); print(x["archive"])')
    NELIBC_ROOT="${NELIBC_PATHS[0]}"
    NELIBC_ARCHIVE="${NELIBC_PATHS[1]}"
  elif [ -z "${NELIBC_ROOT:-}" ] || [ -z "${NELIBC_ARCHIVE:-}" ]; then
    echo 'Provide both NELIBC_ROOT and NELIBC_ARCHIVE, or leave both unset for the pinned source build' >&2
    exit 1
  fi
  python3 tools/private_nelibc.py --source "$NELIBC_ROOT" --archive "$NELIBC_ARCHIVE" --output build/nelibc-private.a
  cp "$NELIBC_ROOT/LICENSE" bin/nelibc-LICENSE
  APP_FLAGS+=(-DNC_MEMORY_NELIBC)
  MEMORY_LIBS=(-Wl,--exclude-libs,nelibc-private.a build/nelibc-private.a -ldl -lm)
  APP_BINARY+="-nelibc"
fi
if [ "$CORE_PROFILE" = freestanding ]; then
  CORE_DIRECTORY="build/core-$APP_IMPL-$MEMORY_IMPL"
  mkdir -p "$CORE_DIRECTORY"
  CORE_OBJECTS=()
  for source in "${APP_SOURCES[@]}"; do
    object="$CORE_DIRECTORY/$(basename "${source%.c}").o"
    "${CC:-gcc}" -std=gnu11 -O3 -flto -fno-semantic-interposition \
      -ffreestanding -fno-builtin -fno-stack-protector \
      ${NATIVE_FLAGS--march=native} -Wall -Wextra -Werror -Isrc \
      -I"$("$PG_CONFIG" --includedir)" "${APP_FLAGS[@]}" -c "$source" -o "$object"
    CORE_OBJECTS+=("$object")
  done
  "${CC:-gcc}" -flto -r -nostdlib "${CORE_OBJECTS[@]}" -o "$CORE_DIRECTORY/application.o"
  python3 tools/audit_core.py "$CORE_DIRECTORY/application.o" --implementation "$APP_IMPL"
  APP_SOURCES=("$CORE_DIRECTORY/application.o")
  APP_BINARY+="-freestanding"
  if [ "$MEMORY_IMPL" = nelibc ]; then
    CORE_BRIDGE=(src/core_memory.c)
    MEMORY_LIBS+=(-Wl,--wrap=memcpy,--wrap=memmove,--wrap=memset)
  fi
fi
"${CC:-gcc}" -std=gnu11 -O3 -flto -fno-semantic-interposition \
  -ffunction-sections -fdata-sections -fstack-protector-strong \
  ${NATIVE_FLAGS--march=native} -Wall -Wextra -Werror \
  -Isrc -I"$("$PG_CONFIG" --includedir)" \
  "${APP_FLAGS[@]}" src/transport.c src/read_policy.c src/reactor.c src/request.c src/bcrypt.c src/db.c src/json_scan.c src/json_dispatch.c "${CORE_BRIDGE[@]}" "${APP_SOURCES[@]}" \
  -L"$("$PG_CONFIG" --libdir)" -Wl,-rpath,"$("$PG_CONFIG" --libdir)" \
  -Wl,--gc-sections -pthread -lpq -lcrypto -lcrypt "${MEMORY_LIBS[@]}" -o "$APP_BINARY"
python3 tools/audit.py --implementation "$APP_IMPL" --memory "$MEMORY_IMPL" --binary "$APP_BINARY"
strip --strip-unneeded "$APP_BINARY"
