#!/bin/bash
# bcrypt flags: -march=native variants vs the current -O3 -funroll-loops (one pinned core, best of 3, lanes 1-8)
cd /root/mc/rbench
for f in "-O3 -funroll-loops" "-O3 -funroll-loops -march=native" "-O3 -march=native" "-O2 -funroll-loops -march=native" "-O3 -funroll-loops -march=native -fno-tree-vectorize"; do
  gcc $f -o b2 bench.c && echo "flags: $f" && taskset -c 7 ./b2 12345678 3 | sed "s/^/rbench2 /"
done
