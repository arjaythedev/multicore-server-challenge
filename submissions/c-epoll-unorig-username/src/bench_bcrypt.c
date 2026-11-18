#ifdef BENCH_BCRYPT
// Standalone bcrypt timing: gcc -DBENCH_BCRYPT ... ; prints ms per hash per lane count (see README).
#include <stdio.h>
#include "common.h"
int main(void) {
  bcrypt_selftest();
  const char *set = "$2a$10$ZSfEoPvlcsj2XfvsSeK25e";
  for (int n = 1; n <= BCRYPT_MAX_LANES; n++) {
    const char *pw[BCRYPT_MAX_LANES], *s[BCRYPT_MAX_LANES];
    size_t pl[BCRYPT_MAX_LANES];
    char out[BCRYPT_MAX_LANES][BCRYPT_LEN + 1];
    for (int i = 0; i < n; i++) { pw[i] = "password123"; pl[i] = 11; s[i] = set; }
    int64_t t0 = now_us();
    int reps = 8;
    for (int r = 0; r < reps; r++) bcrypt_lanes(n, pw, pl, s, out);
    double ms = (now_us() - t0) / 1000.0 / reps;
    printf("lanes %d: %.2f ms/hash (%s)\n", n, ms / n, out[0]);
  }
}
#endif
