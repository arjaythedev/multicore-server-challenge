#!/bin/sh
# Builds bin/conduit as a normal user on the box.
set -e
cd "$(dirname "$0")"
mkdir -p bin
# -O3 -march=native -flto: the request path is hand-written C with no
# allocations; the build is plain because Postgres is the bottleneck on the
# scoring box (70-80% of the CPU), so PGO on the app buys at most a percent.
gcc -std=gnu11 -O3 -march=native -flto -fno-plt -pthread \
    -Wall -Wextra -Wno-unused-parameter \
    -o bin/conduit src/*.c -luring -lcrypt -lm
echo "built bin/conduit:"
ls -la bin/conduit
