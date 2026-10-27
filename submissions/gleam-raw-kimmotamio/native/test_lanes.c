/*
 * Checks the lane-interleaved bcrypt against the reference ts_bcrypt on random inputs and times both.
 *   cc -O3 -o /tmp/test_lanes native/test_lanes.c native/blowfish.c && /tmp/test_lanes
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "bcrypt_lanes.c"

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(void) {
    const char *b64 = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    char keys[LANES][80], salts[LANES][40], outs[LANES][64], ref[LANES][64];
    const char *kp[LANES], *sp[LANES];
    char *op[LANES];
    int t, l, i, n, fails = 0;
    srand(12345);
    for (t = 0; t < 40; t++) {
        n = 1 + t % LANES;
        for (l = 0; l < n; l++) {
            int klen = 1 + rand() % 72;
            for (i = 0; i < klen; i++) keys[l][i] = 33 + rand() % 90;
            keys[l][klen] = 0;
            snprintf(salts[l], sizeof salts[l], "$2%s$%02d$", (t % 3 == 0) ? "b" : "a", (t % 5 == 0) ? 5 : 10);
            for (i = 0; i < 22; i++) salts[l][7 + i] = b64[rand() % 64];
            salts[l][29] = 0;
            kp[l] = keys[l];
            sp[l] = salts[l];
            op[l] = outs[l];
            memset(ref[l], 0, 64);
            if (ts_bcrypt(ref[l], keys[l], salts[l]) != 0) { printf("reference failed\n"); return 1; }
        }
        memset(outs, 0, sizeof outs);
        bcrypt_lanes(n, kp, sp, op);
        for (l = 0; l < n; l++) {
            if (strcmp(ref[l], outs[l]) != 0) {
                fails++;
                printf("MISMATCH n=%d lane=%d key=%s\n  ref=%s\n  got=%s\n", n, l, keys[l], ref[l], outs[l]);
            }
        }
    }
    /* Known vector: "password123" with a fixed salt, cost 10. */
    {
        const char *k = "password123", *s = "$2a$10$ZSfEoPvlcsj2XfvsSeK25e";
        char o[64];
        ts_bcrypt(o, k, s);
        printf("vector %s -> %s\n", s, o);
    }
    printf("%d mismatches over 40 batches\n", fails);
    /* Timing at cost 10. */
    {
        double t0, t1;
        for (l = 0; l < LANES; l++) {
            snprintf(keys[l], sizeof keys[l], "benchmark-password-%d", l);
            snprintf(salts[l], sizeof salts[l], "$2a$10$abcdefghijklmnopqrstu%c", b64[l]);
            kp[l] = keys[l]; sp[l] = salts[l]; op[l] = outs[l];
        }
        t0 = now();
        for (i = 0; i < 8; i++) ts_bcrypt(outs[0], keys[0], salts[0]);
        t1 = now();
        printf("reference: %.1f ms per hash\n", (t1 - t0) * 1000 / 8);
        t0 = now();
        for (i = 0; i < 4; i++) bcrypt_lanes(LANES, kp, sp, op);
        t1 = now();
        printf("%d lanes:   %.1f ms per batch, %.1f ms per hash\n", LANES, (t1 - t0) * 1000 / 4, (t1 - t0) * 1000 / 4 / LANES);
        t0 = now();
        for (i = 0; i < 4; i++) bcrypt_lanes(2, kp, sp, op);
        t1 = now();
        printf("2 of %d lanes: %.1f ms per batch\n", LANES, (t1 - t0) * 1000 / 4);
    }
    return fails != 0;
}
