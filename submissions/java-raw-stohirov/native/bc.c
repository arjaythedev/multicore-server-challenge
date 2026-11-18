// bcrypt's cost loop over the generated expand0 kernels. n lanes of 1042 words sit next to each other in a (P[18], then
// S[4][256]); kw and swk are n * 18 words of key and salt stream. Called from src/conduit/BCryptNative.java.
#include <stdint.h>
#include "bc_kernels.h"

#define WORDS 1042
#define MAX_LANES 6
typedef void (*kernel)(uint32_t *);

static const kernel C_KERNELS[MAX_LANES] = {bc_expand0_c_1, bc_expand0_c_2, bc_expand0_c_3, bc_expand0_c_4, bc_expand0_c_5, bc_expand0_c_6};

#if defined(__x86_64__) && defined(__linux__)
#define D(s) extern void bc_expand0_##s##_1(uint32_t *), bc_expand0_##s##_2(uint32_t *), bc_expand0_##s##_3(uint32_t *), \
    bc_expand0_##s##_4(uint32_t *), bc_expand0_##s##_5(uint32_t *), bc_expand0_##s##_6(uint32_t *);
D(ah)
D(bextr)
static const kernel AH[MAX_LANES] = {bc_expand0_ah_1, bc_expand0_ah_2, bc_expand0_ah_3, bc_expand0_ah_4, bc_expand0_ah_5, bc_expand0_ah_6};
static const kernel BEXTR[MAX_LANES] = {bc_expand0_bextr_1, bc_expand0_bextr_2, bc_expand0_bextr_3, bc_expand0_bextr_4, bc_expand0_bextr_5, bc_expand0_bextr_6};
#endif

// Whether a style can run on this CPU: 0 the C kernels, 1 assembly "ah", 2 assembly "bextr" (these need BMI1 and BMI2).
int bc_style_ok(int style) {
    if (style == 0) return 1;
#if defined(__x86_64__) && defined(__linux__)
    __builtin_cpu_init();
    if (style == 1 || style == 2) return __builtin_cpu_supports("bmi") && __builtin_cpu_supports("bmi2");
#endif
    return 0;
}

static inline void key_in(uint32_t *a, int n, const uint32_t *k) {
    for (int l = 0; l < n; l++)
        for (int i = 0; i < 18; i++) a[l * WORDS + i] ^= k[l * 18 + i];
}

// Returns 0, or -1 for a style or width that doesn't exist.
int bc_cost_loop(uint32_t *a, int n, int style, const uint32_t *kw, const uint32_t *swk, uint64_t rounds) {
    if (n < 1 || n > MAX_LANES || !bc_style_ok(style)) return -1;
    kernel f = C_KERNELS[n - 1];
#if defined(__x86_64__) && defined(__linux__)
    if (style == 1) f = AH[n - 1];
    if (style == 2) f = BEXTR[n - 1];
#endif
    for (uint64_t r = 0; r < rounds; r++) {
        key_in(a, n, kw);
        f(a);
        key_in(a, n, swk);
        f(a);
    }
    return 0;
}
