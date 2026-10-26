#!/usr/bin/env bash
# After build.sh: deterministic primitive checks, no database or load server.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .build/goose.h && -x bin/conduit ]] || {
    echo 'Run build.sh before tests/native.sh.' >&2
    exit 1
}
goose_bin=${GOOSE_BIN:-"$PWD/.goose/build/goose"}
[[ -x $goose_bin ]] || { echo 'Set GOOSE_BIN to the compiler used by build.sh.' >&2; exit 1; }
cc=${CC:-gcc}
out="$PWD/.build/native-checks"
mkdir -p "$out"
"$cc" -O2 -g -std=gnu11 -Wall -Wextra -Werror -I. -I.build \
    tests/native.c json_fast.c native_crypto.c native_sys.c \
    -Wl,--wrap=EVP_MAC_update -lcrypto -pthread -o "$out/native"
"$out/native" | tee "$out/native.json"
"$cc" -O2 -g -std=gnu11 -Wall -Wextra -Werror -I. -I.build \
    tests/pipe-reply.c native_sys.c -Wl,--wrap=write -Wl,--wrap=poll \
    -pthread -o "$out/pipe-reply"
"$out/pipe-reply" | tee "$out/pipe-reply.json"
# Keep module copies and generated test C separate from the application's
# generated C, so these checks can never replace the production executable.
cp tests/jwt-ffi.goose "$out/jwt-ffi.goose"
cp http.goose crypto.goose jwt.goose "$out/"
"$goose_bin" -O2 --standalone -o "$out/jwt-ffi.c" "$out/jwt-ffi.goose"
"$cc" -O2 -std=gnu11 -I.build -pthread "$out/jwt-ffi.c" \
    native_crypto.c json_fast.c -lcrypto -lm -pthread -o "$out/jwt-ffi"
"$out/jwt-ffi" | tee "$out/jwt-ffi.log"
sha256sum native_crypto.c native_sys.c json_fast.c json_fast.h \
    jwt.goose http.goose routes.goose main.goose server.goose \
    tests/native.c tests/pipe-reply.c tests/jwt-ffi.goose tests/native.sh > "$out/source-sha256.txt"
printf '%s\n' 'PASS: native vectors, failure handling, threads, JSON differential, syscall ABI, reliable pipe replies and Goose JWT FFI'
