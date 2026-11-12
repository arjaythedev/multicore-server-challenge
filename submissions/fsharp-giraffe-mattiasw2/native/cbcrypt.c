// bcrypt's 23 hash bytes for 1 to 6 passwords at once, their Blowfish chains stepped in lockstep.
//
// One bcrypt is ~1 M Blowfish encryptions, each feeding the next: a chain of dependent S-box loads, so a single
// hash leaves the core waiting on its cache. The chains of different passwords are independent, so stepping them
// together (round r of every lane, then round r + 1) lets the out-of-order core overlap them.
//
// Nearly all of the time is the cost loop's 2 * 2^cost key expansions. Each is one call of a kernel: on x86-64
// with BMI1 and BMI2 one of the assembly kernels native/gen-bcrypt-x86.py writes (three styles of index-byte
// extraction; which is fastest depends on the CPU, so src/Engine/Bcrypt.fs times them at startup), otherwise, and
// as kernel 0, the C ones below. The salted first expansion and the final 64 encryptions are a thousandth of the
// work and stay in plain C, one lane at a time.
//
// Called from src/Engine/Bcrypt.fs through P/Invoke. No state between calls, nothing allocated: the lanes live on
// the caller's stack and are wiped before returning.
#define _DEFAULT_SOURCE
#include <stdint.h>
#include <string.h>

#define WORDS 1042 // one lane: P[18], then S[4][256]
#define MAX_LANES 6
#define KERNELS 4 // 0: C; 1, 2, 3: assembly "ah", "bextr", "shrx"
#define EXPORT __attribute__((visibility("default")))

typedef void (*kernel)(uint32_t *);

// Blowfish's F over one lane `a`.
#define F(a, x) \
    ((((a)[18 + ((x) >> 24)] + (a)[274 + (((x) >> 16) & 255)]) ^ (a)[530 + (((x) >> 8) & 255)]) + (a)[786 + ((x) & 255)])

// N contiguous lanes with the key (or the salt) already XORed into P: encrypts a zero block and writes its 521
// chained outputs over P and S in turn. N is a constant, so the compiler unrolls the lanes of every round.
#define EXPAND0(N)                                                                                    \
    static void expand0_c_##N(uint32_t *a) {                                                          \
        uint32_t L[N] = {0}, R[N] = {0};                                                              \
        for (int at = 0; at < WORDS; at += 2) {                                                       \
            for (int l = 0; l < N; l++) L[l] ^= a[l * WORDS];                                         \
            for (int r = 1; r <= 15; r += 2) {                                                        \
                for (int l = 0; l < N; l++) R[l] ^= F(a + l * WORDS, L[l]) ^ a[l * WORDS + r];        \
                for (int l = 0; l < N; l++) L[l] ^= F(a + l * WORDS, R[l]) ^ a[l * WORDS + r + 1];    \
            }                                                                                         \
            for (int l = 0; l < N; l++) {                                                             \
                uint32_t t = R[l] ^ a[l * WORDS + 17];                                                \
                R[l] = L[l];                                                                          \
                L[l] = t;                                                                             \
                a[l * WORDS + at] = L[l];                                                             \
                a[l * WORDS + at + 1] = R[l];                                                         \
            }                                                                                         \
        }                                                                                             \
    }
EXPAND0(1) EXPAND0(2) EXPAND0(3) EXPAND0(4) EXPAND0(5) EXPAND0(6)

#define TABLE(f) {f##1, f##2, f##3, f##4, f##5, f##6}
#if defined(__x86_64__) && defined(__linux__)
#define DECLARE(s)                                                                                             \
    extern void bcrypt_expand_##s##_1(uint32_t *), bcrypt_expand_##s##_2(uint32_t *), bcrypt_expand_##s##_3(uint32_t *), \
        bcrypt_expand_##s##_4(uint32_t *), bcrypt_expand_##s##_5(uint32_t *), bcrypt_expand_##s##_6(uint32_t *);
DECLARE(ah) DECLARE(bextr) DECLARE(shrx)
static const kernel kernels[KERNELS][MAX_LANES] = {TABLE(expand0_c_), TABLE(bcrypt_expand_ah_), TABLE(bcrypt_expand_bextr_),
                                                   TABLE(bcrypt_expand_shrx_)};
#else
static const kernel kernels[1][MAX_LANES] = {TABLE(expand0_c_)};
#endif

// The kernels this CPU can run, as a bit mask: bit k is kernel k.
EXPORT int cbcrypt_kernels(void) {
#if defined(__x86_64__) && defined(__linux__)
    __builtin_cpu_init();
    if (__builtin_cpu_supports("bmi") && __builtin_cpu_supports("bmi2")) return (1 << KERNELS) - 1;
#endif
    return 1;
}

// One block through one lane.
static inline void encipher(const uint32_t *a, uint32_t *l, uint32_t *r) {
    uint32_t L = *l ^ a[0], R = *r;
    for (int i = 1; i <= 15; i += 2) {
        R ^= F(a, L) ^ a[i];
        L ^= F(a, R) ^ a[i + 1];
    }
    *l = R ^ a[17];
    *r = L;
}

static inline void xor_words(uint32_t *p, const uint32_t *w) {
    for (int i = 0; i < 18; i++) p[i] ^= w[i];
}

// `lanes` bcrypts (1 to 6) of one cost (4 to 31) with kernel `kernel`.
//   init:        Blowfish's initial state, 1042 words (pi's digits; Bcrypt.fs computes them)
//   keys:        72 bytes a lane, of which the first key_lengths[lane] (1 to 72) are the key: the password's
//                bytes and a NUL, cut at 72
//   salts:       16 bytes a lane
//   hashes:      23 bytes a lane, written here
// Returns 0, or -1 for an argument out of range or a kernel this CPU or build does not have.
EXPORT int cbcrypt_raw(const uint32_t *init, int kernel_id, int cost, int lanes, const uint8_t *keys, const int32_t *key_lengths,
                       const uint8_t *salts, uint8_t *hashes) {
    if (lanes < 1 || lanes > MAX_LANES || cost < 4 || cost > 31 || kernel_id < 0 || kernel_id >= KERNELS ||
        !(cbcrypt_kernels() >> kernel_id & 1))
        return -1;
    for (int l = 0; l < lanes; l++)
        if (key_lengths[l] < 1 || key_lengths[l] > 72) return -1;
    const kernel expand0 = kernels[kernel_id][lanes - 1];

    uint32_t a[MAX_LANES * WORDS] __attribute__((aligned(64)));
    uint32_t key[MAX_LANES][18], salt[MAX_LANES][18];
    for (int l = 0; l < lanes; l++) {
        // Blowfish's key stream: the key's bytes, cyclically, as 18 big-endian words. The salt's likewise.
        const uint8_t *k = keys + l * 72, *s = salts + l * 16;
        int at = 0;
        for (int i = 0; i < 18; i++) {
            uint32_t w = 0;
            for (int b = 0; b < 4; b++) {
                w = w << 8 | k[at];
                at = at + 1 == key_lengths[l] ? 0 : at + 1;
            }
            key[l][i] = w;
            const uint8_t *q = s + (i & 3) * 4;
            salt[l][i] = (uint32_t)q[0] << 24 | (uint32_t)q[1] << 16 | (uint32_t)q[2] << 8 | q[3];
        }
        // The salted expansion: as expand0, but every block is XORed with the next 64 bits of the salt first.
        uint32_t *p = a + l * WORDS, L = 0, R = 0;
        memcpy(p, init, WORDS * sizeof *p);
        xor_words(p, key[l]);
        for (int at2 = 0; at2 < WORDS; at2 += 2) {
            L ^= salt[l][at2 & 2];
            R ^= salt[l][(at2 & 2) + 1];
            encipher(p, &L, &R);
            p[at2] = L;
            p[at2 + 1] = R;
        }
    }

    for (uint64_t round = 0, rounds = 1ULL << cost; round < rounds; round++) {
        for (int l = 0; l < lanes; l++) xor_words(a + l * WORDS, key[l]);
        expand0(a);
        for (int l = 0; l < lanes; l++) xor_words(a + l * WORDS, salt[l]);
        expand0(a);
    }

    for (int l = 0; l < lanes; l++) {
        // "OrpheanBeholderScryDoubt", encrypted 64 times; the hash is its first 23 bytes.
        uint32_t text[6] = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
        for (int b = 0; b < 6; b += 2)
            for (int i = 0; i < 64; i++) encipher(a + l * WORDS, &text[b], &text[b + 1]);
        for (int i = 0; i < 23; i++) hashes[l * 23 + i] = (uint8_t)(text[i / 4] >> (24 - 8 * (i % 4)));
    }
    explicit_bzero(a, sizeof a);
    explicit_bzero(key, sizeof key);
    return 0;
}
