#!/bin/bash
# bcrypt lane state padding (L1 set / 4K aliasing between lanes): pad words after each lane state, -O3 -funroll-loops
cd /root/mc/rbench
for pad in 0 16 48 112 240 496; do
  sed "s/#include \"bcrypt.c\"/#include \"bcrypt-pad.c\"/" bench.c > bench-pad.c
  gcc -O3 -funroll-loops -DPAD=$pad -o bp bench-pad.c && echo "pad: $pad" && taskset -c 7 ./bp 12345678 3 | grep -E "lanes=[4-8]" | sed "s/^/rbpad pad=$pad /"
done
