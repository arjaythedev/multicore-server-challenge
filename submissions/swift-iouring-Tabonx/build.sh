#!/usr/bin/env bash
# Builds bin/server as a normal user: liburing 2.15 from source (SHA-256 checked), bcrypt with -march=native and its assembly kernel,
# then the Swift sources with swiftc, linked statically against the Swift runtime.
set -euo pipefail
cd "$(dirname "$0")"
BIN=/opt/swift/usr/bin
[ -x "$BIN/swiftc" ] || BIN="$(dirname "$(command -v swiftc)")"
DEPS="$PWD/.deps"; OUT="$PWD/.build"; mkdir -p "$DEPS" "$OUT" bin

fetch() { # fetch <url> <file> <sha256>
    [ -f "$2" ] || curl -fsSL "$1" -o "$2"
    echo "$3  $2" | sha256sum -c - >/dev/null
}
URING_VER=2.15
fetch "https://github.com/axboe/liburing/archive/refs/tags/liburing-$URING_VER.tar.gz" "$DEPS/liburing.tar.gz" \
    8d052f2622dcb3678cbaee5ff582a87572672a6c0a56533cdda5b65cb636120a
URING="$DEPS/uring"
if [ ! -f "$URING/lib/liburing.a" ]; then
    tar xzf "$DEPS/liburing.tar.gz" -C "$DEPS"
    (cd "$DEPS/liburing-liburing-$URING_VER" && CC="$BIN/clang" ./configure --prefix="$URING" >/dev/null &&
     make -j"$(nproc)" -s -C src install >/dev/null)
fi

"$BIN/clang" -O2 -ISources/CShim/include -c Sources/CShim/shim.c -o "$OUT/shim.o"
"$BIN/clang" -O2 -I"$URING/include" -ISources/CUring/include -c Sources/CUring/tu.c -o "$OUT/tu.o"
"$BIN/clang" -O3 -march=native -fomit-frame-pointer -ISources/CBcrypt -ISources/CBcrypt/include \
    -c Sources/CBcrypt/bcrypt.c -o "$OUT/bcrypt.o"
"$BIN/clang" -c Sources/CBcrypt/expand0.S -o "$OUT/expand0.o"
"$BIN/swiftc" -wmo -Ounchecked -enforce-exclusivity=unchecked -parse-as-library -swift-version 6 -module-name Server \
    -static-stdlib \
    -I Sources/CShim/include -I Sources/CUring/include -I Sources/CBcrypt/include \
    -Xcc -ISources/CShim/include -Xcc -ISources/CUring/include -Xcc -ISources/CBcrypt/include -Xcc -I"$URING/include" \
    Sources/Server/*.swift "$OUT/shim.o" "$OUT/tu.o" "$OUT/bcrypt.o" "$OUT/expand0.o" -lpthread "$URING/lib/liburing.a" -o bin/server
echo "built bin/server"
