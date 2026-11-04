/* Independent bcrypt hashes interleaved by round. Uses the unmodified public-domain
 * Openwall core for constants, key/salt handling, and the single-hash fallback. */
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

/* Inputs are NUL terminated, outputs have 61 bytes per lane. No aliasing. */
int conduit_bcrypt_batch(const char *const *keys, const char *const *settings,
                         unsigned char (*out)[61], unsigned n) {
    switch (n) {
    case 2: return batch_run2(keys, settings, out);
    case 3: return batch_run3(keys, settings, out);
    case 4: return batch_run4(keys, settings, out);
    default: return 0;
    }
}
