// bcrypt's cost loop (2^cost rounds of key and salt expansion) for 1 to 6 hashes in lockstep, called from
// src/challenge/NativeCost.java. states: lanes of 1042 words (P[18], then S[1024]); inputs: lanes of 22 words (the
// key stream's 18 words, then the salt's 4). Style 0 runs the C kernels below, styles 1-3 the generated x86-64
// kernels in bcrypt_x86_64.S (tools/gen-bcrypt-x86.py), which need BMI1 and BMI2.
#include <stdint.h>

typedef struct { uint32_t P[18], S[1024]; } bf_t;
typedef struct { uint32_t key[18], salt[4]; } lane_in_t;

#define F(c, x) ((((c)->S[(x) >> 24] + (c)->S[256 + (((x) >> 16) & 255)]) \
                  ^ (c)->S[512 + (((x) >> 8) & 255)]) + (c)->S[768 + ((x) & 255)])

static inline __attribute__((always_inline)) void
encipher(bf_t *c, uint32_t *L, uint32_t *R, const int n)
{
#pragma GCC unroll 8
    for (int l = 0; l < n; l++) L[l] ^= c[l].P[0];
#pragma GCC unroll 8
    for (int r = 1; r <= 16; r += 2) {
#pragma GCC unroll 8
        for (int l = 0; l < n; l++) R[l] ^= F(&c[l], L[l]) ^ c[l].P[r];
#pragma GCC unroll 8
        for (int l = 0; l < n; l++) L[l] ^= F(&c[l], R[l]) ^ c[l].P[r + 1];
    }
#pragma GCC unroll 8
    for (int l = 0; l < n; l++) {
        uint32_t t = R[l];
        R[l] = L[l];
        L[l] = t ^ c[l].P[17];
    }
}

static inline __attribute__((always_inline)) void
body(bf_t *c, const int n)
{
    uint32_t L[6] = {0}, R[6] = {0};
    for (int i = 0; i < 18; i += 2) {
        encipher(c, L, R, n);
#pragma GCC unroll 8
        for (int l = 0; l < n; l++) {
            c[l].P[i] = L[l];
            c[l].P[i + 1] = R[l];
        }
    }
    for (int i = 0; i < 1024; i += 2) {
        encipher(c, L, R, n);
#pragma GCC unroll 8
        for (int l = 0; l < n; l++) {
            c[l].S[i] = L[l];
            c[l].S[i + 1] = R[l];
        }
    }
}

#define COST_LOOP(N) \
static __attribute__((noinline)) void cost_loop_##N(bf_t *c, const lane_in_t *in, uint64_t rounds) \
{ \
    while (rounds--) { \
        for (int l = 0; l < N; l++) \
            for (int i = 0; i < 18; i++) c[l].P[i] ^= in[l].key[i]; \
        body(c, N); \
        for (int l = 0; l < N; l++) \
            for (int i = 0; i < 18; i++) c[l].P[i] ^= in[l].salt[i & 3]; \
        body(c, N); \
    } \
}

COST_LOOP(1)
COST_LOOP(2)
COST_LOOP(3)
COST_LOOP(4)
COST_LOOP(5)
COST_LOOP(6)


#define STYLES 4
#define WORDS 1042
typedef void (*kernel)(uint32_t *);

#if defined(__x86_64__) && defined(__linux__)
#define DECLARE(s) extern void bcrypt_expand_##s##_1(uint32_t *), bcrypt_expand_##s##_2(uint32_t *), \
    bcrypt_expand_##s##_3(uint32_t *), bcrypt_expand_##s##_4(uint32_t *), bcrypt_expand_##s##_5(uint32_t *), \
    bcrypt_expand_##s##_6(uint32_t *);
#define TABLE(s) {bcrypt_expand_##s##_1, bcrypt_expand_##s##_2, bcrypt_expand_##s##_3, bcrypt_expand_##s##_4, \
    bcrypt_expand_##s##_5, bcrypt_expand_##s##_6}
DECLARE(ah)
DECLARE(bextr)
DECLARE(shrx)
static const kernel ASM[STYLES - 1][6] = {TABLE(ah), TABLE(bextr), TABLE(shrx)};
#endif

// Bit s set: style s runs on this CPU.
int bcrypt_styles(void)
{
    int styles = 1;
#if defined(__x86_64__) && defined(__linux__)
    __builtin_cpu_init();
    if (__builtin_cpu_supports("bmi") && __builtin_cpu_supports("bmi2"))
        styles |= 0xe;
#endif
    return styles;
}

// Returns 0, or -1 for a style or width that doesn't exist here.
int bcrypt_cost_loop(int lanes, int style, uint64_t rounds, uint32_t *states, const uint32_t *inputs)
{
    if (lanes < 1 || lanes > 6 || style < 0 || style >= STYLES || !(bcrypt_styles() >> style & 1))
        return -1;
    if (style == 0) {
        bf_t *c = (bf_t *) states;
        const lane_in_t *in = (const lane_in_t *) inputs;
        switch (lanes) {
        case 1: cost_loop_1(c, in, rounds); break;
        case 2: cost_loop_2(c, in, rounds); break;
        case 3: cost_loop_3(c, in, rounds); break;
        case 4: cost_loop_4(c, in, rounds); break;
        case 5: cost_loop_5(c, in, rounds); break;
        default: cost_loop_6(c, in, rounds); break;
        }
        return 0;
    }
#if defined(__x86_64__) && defined(__linux__)
    kernel f = ASM[style - 1][lanes - 1];
    while (rounds--) {
        for (int l = 0; l < lanes; l++)
            for (int i = 0; i < 18; i++) states[l * WORDS + i] ^= inputs[l * 22 + i];
        f(states);
        for (int l = 0; l < lanes; l++)
            for (int i = 0; i < 18; i++) states[l * WORDS + i] ^= inputs[l * 22 + 18 + (i & 3)];
        f(states);
    }
#endif
    return 0;
}
