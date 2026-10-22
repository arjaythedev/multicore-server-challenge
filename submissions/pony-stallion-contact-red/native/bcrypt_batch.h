/* Interleaved rounds adapted from rust-tokio-Scooter1337's bcrypt-batch.c
 * and bcrypt-batch-impl.h. MIT: repository LICENSE.
 */
struct BC_data {
    BF_ctx ctx;
    BF_key expanded_key;
    union { BF_word salt[4]; BF_word output[6]; } binary;
};

static void BC_wipe(void *buffer, size_t size)
{
    volatile unsigned char *p = buffer;
#ifdef CONDUIT_PASSWORD_TEST
    conduit_test_wiping(buffer, size);
#endif
    for (size_t i = 0; i < size; i++) p[i] = 0;
#ifdef CONDUIT_PASSWORD_TEST
    conduit_test_wiped(buffer, size);
#endif
}

static inline BF_word BC_f(const BF_ctx *s, BF_word x)
{
    return ((s->S[0][x >> 24] + s->S[1][(x >> 16) & 255]) ^
        s->S[2][(x >> 8) & 255]) + s->S[3][x & 255];
}

#define BC_JOIN_(a,b) a##b
#define BC_JOIN(a,b) BC_JOIN_(a,b)
#define BC_LANES 2
#include "bcrypt_batch_impl.h"
#undef BC_LANES
#define BC_LANES 3
#include "bcrypt_batch_impl.h"
#undef BC_LANES
#define BC_LANES 4
#include "bcrypt_batch_impl.h"
#undef BC_LANES
#undef BC_JOIN
#undef BC_JOIN_

static const char *const BC_guard_keys[] = {
        "guard-one", "guard-two", "guard-three", "guard-four"};
static const size_t BC_guard_lengths[] = {9, 9, 11, 10};
static const char *const BC_guards[] = {
        "$2b$04$..aMDPuhIhC2NyXLTDrgYOP407t1nX/BgL.EZmVAYvT43fol2uzku",
        "$2b$04$CvmfIA60NSPJSjjeX03zd.ah1WDvO5siMl4iwjpg33ICBSjyzZfe6",
        "$2b$04$HgyyMyHHSDbcXUvxcmEGhuBcH2EryysBtxIp.Si61q25gda34W40C",
        "$2b$04$MS/FRjTaW0nvcF8EhXQZmeFCDUeMcD0jglZypNZ9EnJi4QxkBs4nS"};

int _crypt_blowfish_batch_rn(const char *const *keys, const size_t *lengths,
    const char *const *settings, char (*outputs)[61], size_t count)
{
    typedef int (*BC_fn)(const char *const *, const size_t *,
        const char *const *, char (*)[61]);
    BC_fn volatile run;
    char actual[4][61], guard[4][61];
    int okay = 0;
    if (!keys || !lengths || !settings || !outputs) return 0;
    switch (count) {
    case 2: run = BC_run2; break;
    case 3: run = BC_run3; break;
    case 4: run = BC_run4; break;
    default: return 0;
    }
#ifdef CONDUIT_PASSWORD_TEST
    conduit_test_buffers(actual, guard, sizeof(actual), count);
#endif
    if (!run(keys, lengths, settings, actual)) goto cleanup;
    if (!run(BC_guard_keys, BC_guard_lengths, BC_guards, guard)) goto cleanup;
#ifdef CONDUIT_PASSWORD_TEST
    if (!conduit_test_guard(guard, count)) goto cleanup;
#endif
    for (size_t i = 0; i < count; i++)
        if (memcmp(guard[i], BC_guards[i], 61)) goto cleanup;
    int key_okay = BF_key_self_test();
#ifdef CONDUIT_PASSWORD_TEST
    key_okay = conduit_test_key_check(key_okay);
#endif
    if (!key_okay) goto cleanup;
    memcpy(outputs, actual, count * 61);
    okay = 1;
cleanup:
    BC_wipe(actual, sizeof(actual));
    BC_wipe(guard, sizeof(guard));
    return okay;
}

int _crypt_blowfish_batch_selftest(void)
{
    char out[4][61];
    if (!_crypt_blowfish_len_rn(BC_guard_keys[0], BC_guard_lengths[0],
            BC_guards[0], out[0], 61) || memcmp(out[0], BC_guards[0], 61))
        return 0;
    for (size_t count = 2; count <= 4; count++) {
        if (!_crypt_blowfish_batch_rn(BC_guard_keys, BC_guard_lengths,
                BC_guards, out, count)) return 0;
        for (size_t i = 0; i < count; i++)
            if (memcmp(out[i], BC_guards[i], 61)) return 0;
    }
    return 1;
}
