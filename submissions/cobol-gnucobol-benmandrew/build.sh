#!/usr/bin/env bash
# Builds the server -> bin/conduit. COBOL to C with cobc, then gcc -O2. -fnotrunc lets binary fields use their
# whole width, so arithmetic on them needs no decimal range checks. -rdynamic exports crypt_blowfish's symbols
# from the executable, where a COBOL CALL looks them up. libcrypto is also reached only through CALL at run
# time, so --no-as-needed stops the linker from dropping it.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
"${CC:-cc}" -O2 -funroll-loops -c src/crypt_blowfish.c -o bin/crypt_blowfish.o
"${COBC:-cobc}" -x -free -O2 -fnotrunc -I src -Q -rdynamic -Q -Wl,--no-as-needed -o bin/conduit src/conduit.cob bin/crypt_blowfish.o -lcrypto
echo "built bin/conduit"
