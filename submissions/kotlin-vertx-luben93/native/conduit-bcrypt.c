/* conduit-bcrypt: see conduit-bcrypt.h. Built with -O3 and no -m flags (the box's CPU is unknown): JVM build by
 * build.sh with the system C compiler into a shared library, Kotlin/Native build through cinterop
 * (src/nativeInterop/cinterop/bcrypt.def) with Kotlin/Native's own clang. */
#include "bcrypt-batch.c" /* crypt-bcrypt.c, then the interleave for 2, 3 and 4 lanes */

static void wipe(void *p, size_t n) {
    volatile unsigned char *v = p;
    while (n--) *v++ = 0;
}

#include "conduit-bcrypt.h"

#define LANES 1
#include "bcrypt-batch-impl.h"
#include "conduit-bcrypt-lanes.h"
#undef LANES
#define LANES 2
#include "conduit-bcrypt-lanes.h"
#undef LANES
#define LANES 3
#include "conduit-bcrypt-lanes.h"
#undef LANES
#define LANES 4
#include "conduit-bcrypt-lanes.h"
#undef LANES
#define LANES 6
#include "bcrypt-batch-impl.h"
#include "conduit-bcrypt-lanes.h"
#undef LANES
#define LANES 8
#include "bcrypt-batch-impl.h"
#include "conduit-bcrypt-lanes.h"
#undef LANES

int conduit_bf_lanes(int n, const int32_t *keys, const int32_t *salts, int cost, int32_t *out) {
    if (cost < 0 || cost > 31) return 0;
    const unsigned u = (unsigned)n, c = (unsigned)cost;
    switch (n) {
    case 1: lanes_run1(u, keys, salts, c, out); return 1;
    case 2: lanes_run2(u, keys, salts, c, out); return 1;
    case 3: lanes_run3(u, keys, salts, c, out); return 1;
    case 4: lanes_run4(u, keys, salts, c, out); return 1;
    case 5:
    case 6: lanes_run6(u, keys, salts, c, out); return 1;
    case 7:
    case 8: lanes_run8(u, keys, salts, c, out); return 1;
    default: return 0;
    }
}

/* Self-test vectors: Openwall's own test key, high bytes, the 72-byte cutoff, UTF-8; $2b$ and $2y$; one cost. */
#define ST_N 8
static const char *const st_keys[ST_N] = {
    "U*U",
    "",
    "\xa3",
    "8b \xd0\xc1\xd2\xcf\xcc\xd8",
    "password123",
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored",
    "\xff\xa3" "34" "\xff\xff\xff\xa3" "345",
    "\xc3\xa9\xc3\xa9n \xf0\x9f\x99\x82",
};
static const char *const st_settings[ST_N] = {
    "$2b$05$CCCCCCCCCCCCCCCCCCCCC.",
    "$2y$05$XXXXXXXXXXXXXXXXXXXXXO",
    "$2b$05$/OK.fbVrR/bpIqNJ5ianF.",
    "$2y$05$abcdefghijklmnopqrstuu",
    "$2b$05$ZSfEoPvlcsj2XfvsSeK25e",
    "$2b$05$abcdefghijklmnopqrstuu",
    "$2y$05$/OK.fbVrR/bpIqNJ5ianF.",
    "$2b$05$......................",
};

int conduit_bf_self_test(void) {
    struct BF_buffer scratch;
    unsigned char want[ST_N][CRYPT_OUTPUT_SIZE];
    int32_t keys[ST_N * 18], salts[ST_N * 4], k[ST_N * 18], s[ST_N * 4], out[ST_N * 6];
    int failed = 0;
    for (unsigned v = 0; v < ST_N && !failed; v++) {
        const char *set = st_settings[v];
        BF_key expanded, initial;
        BF_word salt[4];
        memset(want[v], 0, sizeof(want[v]));
        crypt_bcrypt_rn(st_keys[v], 0, set, 0, want[v], sizeof(want[v]), &scratch, sizeof(scratch));
        if (want[v][0] != '$' || BF_decode(salt, set + 7, 16)) { failed = -1; break; }
        BF_swap(salt, 4);
        BF_set_key(st_keys[v], expanded, initial, flags_by_subtype[(unsigned)(unsigned char)set[2] - 'a']);
        for (unsigned i = 0; i < 18; i++) keys[v * 18 + i] = (int32_t)expanded[i];
        for (unsigned i = 0; i < 4; i++) salts[v * 4 + i] = (int32_t)salt[i];
        wipe(expanded, sizeof(expanded));
        wipe(initial, sizeof(initial));
    }
    for (unsigned n = 1; n <= CONDUIT_BF_MAX_LANES && !failed; n++) {
        for (unsigned rot = 0; rot < ST_N && !failed; rot += 5) { /* two placements of the vectors in the lanes */
            for (unsigned l = 0; l < n; l++) {
                const unsigned v = (l + rot) % ST_N;
                memcpy(k + l * 18, keys + v * 18, 18 * sizeof(int32_t));
                memcpy(s + l * 4, salts + v * 4, 4 * sizeof(int32_t));
            }
            if (!conduit_bf_lanes((int)n, k, s, 5, out)) { failed = (int)n; break; }
            for (unsigned l = 0; l < n; l++) {
                BF_word o[6];
                unsigned char enc[32];
                for (unsigned i = 0; i < 6; i++) o[i] = (BF_word)out[l * 6 + i];
                BF_swap(o, 6);
                BF_encode(enc, o, 23); /* 31 chars, as in BF_crypt */
                if (memcmp(enc, want[(l + rot) % ST_N] + BF_SETTING_LENGTH, 31)) { failed = (int)n; break; }
            }
        }
    }
    wipe(&scratch, sizeof(scratch));
    wipe(keys, sizeof(keys));
    wipe(k, sizeof(k));
    wipe(out, sizeof(out));
    return failed;
}
