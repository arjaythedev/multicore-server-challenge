#!/usr/bin/env bash
# Build the pinned Goose compiler from source, then generated Goose and our
# native byte/crypto primitives together. No prebuilt application is downloaded.
set -euo pipefail
cd "$(dirname "$0")"

goose_commit=f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a
goose_sha=86482df9e11ff9472d2214e93a71cd7f22b05d31260f66d7e760d5df784a7e92
if [[ -n ${GOOSE_BIN:-} ]]; then
    goose_bin=$(readlink -f "$GOOSE_BIN")
    goose_source=$(cd "$(dirname "$goose_bin")/.." && pwd)
else
    goose_source="$PWD/.goose"
    goose_bin="$goose_source/build/goose"
    if [[ ! -x $goose_bin || ! -f $goose_source/COMMIT || $(cat "$goose_source/COMMIT") != "$goose_commit" ]]; then
        mkdir -p .deps
        archive="$PWD/.deps/goose-$goose_commit.tar.gz"
        if [[ ! -f $archive ]]; then
            curl -fsSL --retry 3 "https://codeload.github.com/aardappel/goose/tar.gz/$goose_commit" -o "$archive"
        fi
        printf '%s  %s\n' "$goose_sha" "$archive" | sha256sum -c -
        rm -rf "$goose_source"
        mkdir -p "$goose_source"
        tar -xzf "$archive" --strip-components=1 -C "$goose_source"
        cmake -S "$goose_source" -B "$goose_source/build" -DCMAKE_BUILD_TYPE=Release -DGOOSE_BUILTIN_LIBS=
        cmake --build "$goose_source/build" --parallel "${BUILD_JOBS:-4}"
        printf '%s\n' "$goose_commit" > "$goose_source/COMMIT"
    fi
fi
[[ -x $goose_bin && -f $goose_source/src/runtime/goose.h ]] || {
    echo 'The pinned Goose executable and its adjacent source tree are required.' >&2
    exit 1
}
[[ $("$goose_bin" version) == 'goose runtime df5f78ce88d4' ]] || {
    echo "Expected Goose compiler $goose_commit (runtime df5f78ce88d4)." >&2
    exit 1
}
mkdir -p .build bin
"$goose_bin" -O2 --standalone -o .build/main.c main.goose
cp "$goose_source/src/runtime/goose.h" .build/goose.h
cc=${CC:-gcc}
"$cc" -O3 -march=native -DNDEBUG -std=gnu11 -flto=2 -fno-semantic-interposition -fno-plt \
    -I.build -pthread .build/main.c json_fast.c native_crypto.c native_sys.c \
    -lcrypto -lm -pthread -o bin/conduit
"$goose_bin" version
"$cc" --version | head -1
sha256sum bin/conduit
