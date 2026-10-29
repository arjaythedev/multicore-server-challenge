/* bcrypt: a C wrapper around Solar Designer's public-domain Openwall bcrypt core (crypt-bcrypt.c, unmodified from
 * libxcrypt 4.4.36) and a lane-interleaved driver (bcrypt-batch-impl.h, from PR #7, rust-tokio-Scooter1337, MIT).
 * Up to six independent hashes run interleaved round by round: one bcrypt is a long chain of dependent S-box loads,
 * and independent chains let the core overlap them. Every hash runs all 2^cost rounds with its own salt.
 */
#include <time.h>
#include "crypt-bcrypt.c"
#include "bcrypt.h"

static inline BF_word batch_f(const BF_ctx *s, BF_word x) {
    return ((s->S[0][x >> 24] + s->S[1][(x >> 16) & 255]) ^
             s->S[2][(x >> 8) & 255]) + s->S[3][x & 255];
}
#define JOIN_(a,b) a##b
#define JOIN(a,b) JOIN_(a,b)
#define LANES 2
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 3
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 4
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 5
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 6
#include "bcrypt-batch-impl.h"
#undef LANES

/* one hash with the original code (any cost); returns 1 on success */
static int single(const char *key, const char *setting, unsigned char out[61]) {
    unsigned char buf[CRYPT_OUTPUT_SIZE];
    static __thread unsigned char scratch[ALG_SPECIFIC_SIZE];
    buf[0] = 0;
    crypt_bcrypt_rn(key, strlen(key), setting, strlen(setting), buf, sizeof buf, scratch, sizeof scratch);
    if (buf[0] != '$' || strlen((const char *)buf) != 60) return 0;
    memcpy(out, buf, 61);
    return 1;
}

int bc_hash(const char *const *keys, const char *const *settings, unsigned char (*out)[61], unsigned n) {
    switch (n) {
    case 1: return single(keys[0], settings[0], out[0]);
    case 2: return batch_run2(keys, settings, out);
    case 3: return batch_run3(keys, settings, out);
    case 4: return batch_run4(keys, settings, out);
    case 5: return batch_run5(keys, settings, out);
    case 6: return batch_run6(keys, settings, out);
    default: return 0;
    }
}

/* Every lane count against the original implementation, with different passwords and salts per lane. */
static const char *T_PW[BC_MAX_LANES] = { "password123", "", "U*U*U*U", "a fairly long password, 0123456789 0123456789 012",
                                          "\xc3\xbc" "n" "\xc3\xaf" "c" "\xc3\xb6" "de", "72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes" };
static const char *T_ST[BC_MAX_LANES] = {
    "$2a$05$CCCCCCCCCCCCCCCCCCCCC.", "$2b$05$abcdefghijklmnopqrstuu", "$2y$05$/OK.fbVrR/bpIqNJ5ianF.",
    "$2a$05$ZSfEoPvlcsj2XfvsSeK25e", "$2b$05$9a8b7c6d5e4f3g2h1i0jkO", "$2a$05$ABCDEFGHIJKLMNOPQRSTUu" };

int bc_selftest(void) {
    unsigned char want[BC_MAX_LANES][61], got[BC_MAX_LANES][61];
    int ok = 1;
    for (int i = 0; i < BC_MAX_LANES; i++) ok &= single(T_PW[i], T_ST[i], want[i]);
    /* a known answer for the original code: Openwall's test vector */
    unsigned char kat[61];
    ok &= single("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.", kat);
    ok &= memcmp(kat, "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW", 61) == 0;
    for (unsigned n = 2; n <= BC_MAX_LANES && ok; n++) {
        ok &= bc_hash(T_PW, T_ST, got, n);
        for (unsigned i = 0; i < n; i++) ok &= memcmp(want[i], got[i], 61) == 0;
    }
    return ok;
}

/* nanoseconds per hash of an n-lane cost-6 run (three runs), to pick the fastest lane count on this CPU */
double bc_calibrate(unsigned n) {
    if (n < 1 || n > BC_MAX_LANES) n = 1;
    const char *st[BC_MAX_LANES];
    for (unsigned i = 0; i < BC_MAX_LANES; i++) st[i] = "$2b$06$abcdefghijklmnopqrstuu";
    unsigned char out[BC_MAX_LANES][61];
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (int r = 0; r < 3; r++) bc_hash(T_PW, st, out, n);
    clock_gettime(CLOCK_MONOTONIC, &b);
    return ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec)) / 3.0 / n;
}
