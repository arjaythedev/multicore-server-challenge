#!/bin/sh
# Builds bin/conduit as a normal user on the box.
set -e
cd "$(dirname "$0")"
mkdir -p bin obj
# -O3 -march=native -flto: the request path is hand-written C with no
# allocations; the build is plain because Postgres is the bottleneck on the
# scoring box (70-80% of the CPU), so PGO on the app buys at most a percent.
#
# libco (Tencent, Apache-2.0, vendored under src/libco) is compiled as C++
# and linked into the same binary; our glue (src/coro.cpp) is C++ only
# because libco's headers are.
gcc -std=gnu11 -O3 -march=native -flto -fno-plt -pthread \
    -Wall -Wextra -Wno-unused-parameter ${CFLAGS:-} \
    -c src/*.c src/libco/coctx_swap.S
for f in coctx co_routine co_epoll co_hook_sys_call co_comm; do
    g++ -O3 -march=native -flto -fno-plt -fno-exceptions -fno-rtti -c ${CFLAGS:-} \
        -Isrc/libco -o "obj/$f.o" "src/libco/$f.cpp"
done
g++ -O3 -march=native -flto -fno-plt -fno-exceptions -fno-rtti -c ${CFLAGS:-} \
    -Isrc/libco -o obj/coro.o src/coro.cpp
g++ -O3 -march=native -flto -pthread -o bin/conduit *.o obj/*.o ${LDFLAGS:-} -luring -lcrypt -lm
rm -f *.o
echo "built bin/conduit:"
ls -la bin/conduit
