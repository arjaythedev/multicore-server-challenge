/* bcrypt for Node: N-API wrapper around Solar Designer's public-domain Openwall bcrypt core (crypt-bcrypt.c,
 * unmodified from libxcrypt 4.4.36) and a lane-interleaved driver (bcrypt-batch-impl.h, from PR #7,
 * rust-tokio-Scooter1337, MIT). Up to six independent hashes run interleaved round by round: one bcrypt is a long
 * chain of dependent S-box loads, and independent chains let the core overlap them. Every hash runs all 2^cost
 * rounds with its own salt; nothing is reused between hashes.
 *
 *   hash(keys: Buffer[], settings: string[]) -> (string | null)[]
 *     keys: passwords (at most 72 bytes, no NUL); settings: "$2a$10$<salt>" or a full stored hash.
 *     1..6 entries; 2..6 must share one cost. Returns the 60-character hashes (null if a setting is invalid).
 *   selfTest() -> boolean: every lane count against the original single-hash code.
 *   calibrate(n) -> ns per hash of an n-lane cost-6 run, to pick the fastest lane count on this CPU.
 */
#define NAPI_VERSION 8
#include <node_api.h>
#include <errno.h>
#include <stdlib.h>
#include <time.h>
#include "crypt-bcrypt.c"

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
#define MAX_LANES 6

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

static int run(const char *const *keys, const char *const *settings, unsigned char (*out)[61], unsigned n) {
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

#define CHECK(call) do { if ((call) != napi_ok) { napi_throw_error(env, NULL, "bcrypt: napi call failed"); return NULL; } } while (0)

static napi_value Hash(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    CHECK(napi_get_cb_info(env, info, &argc, argv, NULL, NULL));
    if (argc < 2) { napi_throw_type_error(env, NULL, "hash(keys, settings)"); return NULL; }
    uint32_t n, n2;
    CHECK(napi_get_array_length(env, argv[0], &n));
    CHECK(napi_get_array_length(env, argv[1], &n2));
    if (n < 1 || n > MAX_LANES || n != n2) { napi_throw_range_error(env, NULL, "1 to 6 hashes"); return NULL; }
    char keys[MAX_LANES][73], settings[MAX_LANES][64];
    const char *kp[MAX_LANES], *sp[MAX_LANES];
    unsigned char out[MAX_LANES][61];
    for (uint32_t i = 0; i < n; i++) {
        napi_value k, s;
        void *data; size_t len;
        CHECK(napi_get_element(env, argv[0], i, &k));
        CHECK(napi_get_element(env, argv[1], i, &s));
        CHECK(napi_get_buffer_info(env, k, &data, &len));
        if (len > 72 || memchr(data, 0, len)) { napi_throw_range_error(env, NULL, "password over 72 bytes or with NUL"); return NULL; }
        memcpy(keys[i], data, len); keys[i][len] = 0;
        size_t sl;
        CHECK(napi_get_value_string_latin1(env, s, settings[i], sizeof settings[i], &sl));
        kp[i] = keys[i]; sp[i] = settings[i];
    }
    int ok = run(kp, sp, out, n);
    volatile char *wipe = (volatile char *)keys;
    for (size_t i = 0; i < sizeof keys; i++) wipe[i] = 0;
    napi_value arr;
    CHECK(napi_create_array_with_length(env, n, &arr));
    for (uint32_t i = 0; i < n; i++) {
        napi_value v;
        if (ok) CHECK(napi_create_string_latin1(env, (const char *)out[i], 60, &v));
        else CHECK(napi_get_null(env, &v));
        CHECK(napi_set_element(env, arr, i, v));
    }
    return arr;
}

/* Every lane count against the original implementation, with different passwords and salts per lane. */
static const char *T_PW[MAX_LANES] = { "password123", "", "U*U*U*U", "a fairly long password, 0123456789 0123456789 012",
                                       "\xc3\xbc" "n" "\xc3\xaf" "c" "\xc3\xb6" "de", "72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes" };
static const char *T_ST[MAX_LANES] = {
    "$2a$05$CCCCCCCCCCCCCCCCCCCCC.", "$2b$05$abcdefghijklmnopqrstuu", "$2y$05$/OK.fbVrR/bpIqNJ5ianF.",
    "$2a$05$ZSfEoPvlcsj2XfvsSeK25e", "$2b$05$9a8b7c6d5e4f3g2h1i0jkO", "$2a$05$ABCDEFGHIJKLMNOPQRSTUu" };

static napi_value SelfTest(napi_env env, napi_callback_info info) {
    (void)info;
    unsigned char want[MAX_LANES][61], got[MAX_LANES][61];
    int ok = 1;
    for (int i = 0; i < MAX_LANES; i++) ok &= single(T_PW[i], T_ST[i], want[i]);
    for (unsigned n = 2; n <= MAX_LANES && ok; n++) {
        ok &= run(T_PW, T_ST, got, n);
        for (unsigned i = 0; i < n; i++) ok &= memcmp(want[i], got[i], 61) == 0;
    }
    napi_value r;
    CHECK(napi_get_boolean(env, ok, &r));
    return r;
}

/* calibrate(lanes) -> nanoseconds per hash for a cost-6 run of that many lanes (to pick the lane count) */
static napi_value Calibrate(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    CHECK(napi_get_cb_info(env, info, &argc, argv, NULL, NULL));
    uint32_t n = 1;
    if (argc > 0) CHECK(napi_get_value_uint32(env, argv[0], &n));
    if (n < 1 || n > MAX_LANES) n = 1;
    const char *st[MAX_LANES];
    for (unsigned i = 0; i < MAX_LANES; i++) st[i] = "$2b$06$abcdefghijklmnopqrstuu";
    unsigned char out[MAX_LANES][61];
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (int r = 0; r < 3; r++) run(T_PW, st, out, n);
    clock_gettime(CLOCK_MONOTONIC, &b);
    double ns = ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec)) / 3.0 / n;
    napi_value r;
    CHECK(napi_create_double(env, ns, &r));
    return r;
}

NAPI_MODULE_INIT() {
    napi_value f;
    if (napi_create_function(env, "hash", NAPI_AUTO_LENGTH, Hash, NULL, &f) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "hash", f) != napi_ok) return NULL;
    if (napi_create_function(env, "selfTest", NAPI_AUTO_LENGTH, SelfTest, NULL, &f) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "selfTest", f) != napi_ok) return NULL;
    if (napi_create_function(env, "calibrate", NAPI_AUTO_LENGTH, Calibrate, NULL, &f) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "calibrate", f) != napi_ok) return NULL;
    return exports;
}
