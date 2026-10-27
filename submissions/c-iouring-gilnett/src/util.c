#include "conduit.h"
#include <math.h>
#include <time.h>
#include <immintrin.h>

// ---------- dynamic buffer & per-request bump arena ----------

void buf_grow(buf_t *b, size_t add) {
    size_t need = b->len + add, cap = b->cap ? b->cap * 2 : 512;
    while (cap < need) cap *= 2;
    char *p = realloc(b->p, cap);
    if (!p) die("out of memory");
    b->p = p;
    b->cap = cap;
}

void buf_free(buf_t *b) {
    free(b->p);
    *b = (buf_t){0};
}

void buf_i64(buf_t *b, int64_t v) {
    buf_reserve(b, 24);
    char tmp[24];
    uint64_t u = v < 0 ? -(uint64_t)v : (uint64_t)v;
    int i = 24;
    do {
        tmp[--i] = (char)('0' + (u % 10));
        u /= 10;
    } while (u);
    if (v < 0) tmp[--i] = '-';
    size_t n = 24 - (size_t)i;
    memcpy(b->p + b->len, tmp + i, n);
    b->len += n;
}

// SIMD AVX2-accelerated JSON string serializer: scans in 32-byte vectors and copies clean runs with memcpy.
void buf_json_str(buf_t *b, const char *s, size_t n) {
    buf_reserve(b, n * 2 + 2);
    b->p[b->len++] = '"';
    size_t run_start = 0;
    size_t i = 0;

#if defined(__AVX2__)
    const __m256i v_quote = _mm256_set1_epi8('"');
    const __m256i v_slash = _mm256_set1_epi8('\\');
    const __m256i v_ctrl  = _mm256_set1_epi8(0x1F);

    while (i + 32 <= n) {
        __m256i chunk = _mm256_loadu_si256((const __m256i *)(s + i));
        __m256i eq_q = _mm256_cmpeq_epi8(chunk, v_quote);
        __m256i eq_s = _mm256_cmpeq_epi8(chunk, v_slash);
        __m256i is_ctrl = _mm256_cmpeq_epi8(_mm256_min_epu8(chunk, v_ctrl), chunk);

        __m256i needs_esc = _mm256_or_si256(_mm256_or_si256(eq_q, eq_s), is_ctrl);
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(needs_esc);

        if (__builtin_expect(mask == 0, 1)) {
            i += 32;
            continue;
        }

        while (mask != 0) {
            int pos = __builtin_ctz(mask);
            size_t esc_idx = i + (size_t)pos;
            if (esc_idx > run_start) {
                buf_put(b, s + run_start, esc_idx - run_start);
            }
            unsigned char c = (unsigned char)s[esc_idx];
            if (c == '"' || c == '\\') {
                const char esc[2] = {'\\', (char)c};
                buf_put(b, esc, 2);
            } else {
                static const char hex[] = "0123456789abcdef";
                switch (c) {
                case '\b': buf_lit(b, "\\b"); break;
                case '\f': buf_lit(b, "\\f"); break;
                case '\n': buf_lit(b, "\\n"); break;
                case '\r': buf_lit(b, "\\r"); break;
                case '\t': buf_lit(b, "\\t"); break;
                default: {
                    const char u[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
                    buf_put(b, u, 6);
                    break;
                }
                }
            }
            run_start = esc_idx + 1;
            mask &= mask - 1;
        }
        i += 32;
    }
#endif

    while (i < n) {
        unsigned char c = (unsigned char)s[i];
        if (__builtin_expect(c < 0x20 || c == '"' || c == '\\', 0)) {
            if (i > run_start) {
                buf_put(b, s + run_start, i - run_start);
            }
            if (c == '"' || c == '\\') {
                const char esc[2] = {'\\', (char)c};
                buf_put(b, esc, 2);
            } else {
                static const char hex[] = "0123456789abcdef";
                switch (c) {
                case '\b': buf_lit(b, "\\b"); break;
                case '\f': buf_lit(b, "\\f"); break;
                case '\n': buf_lit(b, "\\n"); break;
                case '\r': buf_lit(b, "\\r"); break;
                case '\t': buf_lit(b, "\\t"); break;
                default: {
                    const char u[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
                    buf_put(b, u, 6);
                    break;
                }
                }
            }
            run_start = i + 1;
        }
        i++;
    }
    if (n > run_start) {
        buf_put(b, s + run_start, n - run_start);
    }
    buf_putc(b, '"');
}

void *arena_alloc(arena_t *a, size_t n) {
    n = (n + 7) & ~(size_t)7;
    if (!a->head && a->used + n <= sizeof(a->inline_buf)) {
        void *p = a->inline_buf + a->used;
        a->used += n;
        return p;
    }
    arena_blk_t *blk = a->head;
    if (blk && blk->used + n <= blk->cap) {
        void *p = blk->data + blk->used;
        blk->used += n;
        return p;
    }
    size_t cap = n > 16384 ? n : 16384;
    blk = malloc(sizeof(arena_blk_t) + cap);
    if (!blk) die("out of memory");
    blk->next = a->head;
    blk->used = n;
    blk->cap = cap;
    a->head = blk;
    return blk->data;
}

char *arena_strdup(arena_t *a, const char *s, size_t n) {
    char *p = arena_alloc(a, n + 1);
    memcpy(p, s, n);
    p[n] = 0;
    return p;
}

str_t arena_i64(arena_t *a, int64_t v) {
    char *p = arena_alloc(a, 24);
    uint64_t u = v < 0 ? -(uint64_t)v : (uint64_t)v;
    int i = 23;
    p[i] = 0;
    do {
        p[--i] = '0' + (u % 10);
        u /= 10;
    } while (u);
    if (v < 0) p[--i] = '-';
    return (str_t){p + i, (size_t)(23 - i)};
}

void arena_reset(arena_t *a) {
    if (a->head) {
        arena_blk_t *b = a->head->next;
        while (b) {
            arena_blk_t *nx = b->next;
            free(b);
            b = nx;
        }
        if (a->head->cap <= 65536) {
            a->head->next = NULL;
            a->head->used = 0;
        } else {
            free(a->head);
            a->head = NULL;
        }
    }
    a->used = 0;
}

// ---------- integer parsing & URL decoding ----------

bool parse_uint(const char *s, size_t n, int64_t *out) {
    if (n == 0 || n > 19) return false;
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned d = (unsigned)(s[i] - '0');
        if (d > 9) return false;
        if (v > (UINT64_MAX - d) / 10) return false;
        v = v * 10 + d;
    }
    if (v > INT64_MAX) return false;
    *out = (int64_t)v;
    return true;
}

bool parse_i64(const char *s, size_t n, int64_t *out) {
    if (n == 0) return false;
    if (s[0] == '-') {
        int64_t v;
        if (!parse_uint(s + 1, n - 1, &v)) return false;
        *out = -v;
        return true;
    }
    return parse_uint(s, n, out);
}

static inline int hexv(char c) {
    unsigned char u = (unsigned char)c;
    if (__builtin_expect(u >= '0' && u <= '9', 1)) return (int)(u - '0');
    if (u >= 'a' && u <= 'f') return (int)(u - 'a' + 10);
    if (u >= 'A' && u <= 'F') return (int)(u - 'A' + 10);
    return -1;
}

int url_decode(char *dst, const char *src, size_t n) {
    size_t j = 0;
    for (size_t i = 0; i < n; i++) {
        if (src[i] == '%') {
            if (i + 2 >= n) return -1;
            int hi = hexv(src[i + 1]), lo = hexv(src[i + 2]);
            if (hi < 0 || lo < 0) return -1;
            char ch = (char)((hi << 4) | lo);
            if (ch == 0 || ch == '/') return -1;
            dst[j++] = ch;
            i += 2;
        } else {
            dst[j++] = src[i];
        }
    }
    return (int)j;
}

// ---------- FIPS 180-4 SHA-256 & RFC 2104 HMAC-SHA256 ----------

#if !defined(__SHA__) || !defined(__SSSE3__)
static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static inline uint32_t ror32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
#endif

#if defined(__SHA__) && defined(__SSSE3__)
static void sha256_block_shani(uint32_t state[8], const uint8_t data[64]) {
    __m128i STATE0, STATE1;
    __m128i MSG, TMP;
    __m128i MSG0, MSG1, MSG2, MSG3;
    __m128i ABEF_SAVE, CDGH_SAVE;
    const __m128i MASK = _mm_set_epi64x(0x0c0d0e0f08090a0bULL, 0x0405060700010203ULL);

    TMP = _mm_loadu_si128((const __m128i*) &state[0]);
    STATE1 = _mm_loadu_si128((const __m128i*) &state[4]);

    TMP = _mm_shuffle_epi32(TMP, 0xB1);
    STATE1 = _mm_shuffle_epi32(STATE1, 0x1B);
    STATE0 = _mm_alignr_epi8(TMP, STATE1, 8);
    STATE1 = _mm_blend_epi16(STATE1, TMP, 0xF0);

    ABEF_SAVE = STATE0;
    CDGH_SAVE = STATE1;

    MSG = _mm_loadu_si128((const __m128i*) (data + 0));
    MSG0 = _mm_shuffle_epi8(MSG, MASK);
    MSG = _mm_add_epi32(MSG0, _mm_set_epi64x(0xE9B5DBA5B5C0FBCFULL, 0x71374491428A2F98ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);

    MSG1 = _mm_loadu_si128((const __m128i*) (data + 16));
    MSG1 = _mm_shuffle_epi8(MSG1, MASK);
    MSG = _mm_add_epi32(MSG1, _mm_set_epi64x(0xAB1C5ED5923F82A4ULL, 0x59F111F13956C25BULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG0 = _mm_sha256msg1_epu32(MSG0, MSG1);

    MSG2 = _mm_loadu_si128((const __m128i*) (data + 32));
    MSG2 = _mm_shuffle_epi8(MSG2, MASK);
    MSG = _mm_add_epi32(MSG2, _mm_set_epi64x(0x550C7DC3243185BEULL, 0x12835B01D807AA98ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG1 = _mm_sha256msg1_epu32(MSG1, MSG2);

    MSG3 = _mm_loadu_si128((const __m128i*) (data + 48));
    MSG3 = _mm_shuffle_epi8(MSG3, MASK);
    MSG = _mm_add_epi32(MSG3, _mm_set_epi64x(0xC19BF1749BDC06A7ULL, 0x80DEB1FE72BE5D74ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG3, MSG2, 4);
    MSG0 = _mm_add_epi32(MSG0, TMP);
    MSG0 = _mm_sha256msg2_epu32(MSG0, MSG3);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG2 = _mm_sha256msg1_epu32(MSG2, MSG3);

    MSG = _mm_add_epi32(MSG0, _mm_set_epi64x(0x240CA1CC0FC19DC6ULL, 0xEFBE4786E49B69C1ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG0, MSG3, 4);
    MSG1 = _mm_add_epi32(MSG1, TMP);
    MSG1 = _mm_sha256msg2_epu32(MSG1, MSG0);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG3 = _mm_sha256msg1_epu32(MSG3, MSG0);

    MSG = _mm_add_epi32(MSG1, _mm_set_epi64x(0x76F988DA5CB0A9DCULL, 0x4A7484AA2DE92C6FULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG1, MSG0, 4);
    MSG2 = _mm_add_epi32(MSG2, TMP);
    MSG2 = _mm_sha256msg2_epu32(MSG2, MSG1);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG0 = _mm_sha256msg1_epu32(MSG0, MSG1);

    MSG = _mm_add_epi32(MSG2, _mm_set_epi64x(0xBF597FC7B00327C8ULL, 0xA831C66D983E5152ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG2, MSG1, 4);
    MSG3 = _mm_add_epi32(MSG3, TMP);
    MSG3 = _mm_sha256msg2_epu32(MSG3, MSG2);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG1 = _mm_sha256msg1_epu32(MSG1, MSG2);

    MSG = _mm_add_epi32(MSG3, _mm_set_epi64x(0x1429296706CA6351ULL,  0xD5A79147C6E00BF3ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG3, MSG2, 4);
    MSG0 = _mm_add_epi32(MSG0, TMP);
    MSG0 = _mm_sha256msg2_epu32(MSG0, MSG3);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG2 = _mm_sha256msg1_epu32(MSG2, MSG3);

    MSG = _mm_add_epi32(MSG0, _mm_set_epi64x(0x53380D134D2C6DFCULL, 0x2E1B213827B70A85ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG0, MSG3, 4);
    MSG1 = _mm_add_epi32(MSG1, TMP);
    MSG1 = _mm_sha256msg2_epu32(MSG1, MSG0);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG3 = _mm_sha256msg1_epu32(MSG3, MSG0);

    MSG = _mm_add_epi32(MSG1, _mm_set_epi64x(0x92722C8581C2C92EULL, 0x766A0ABB650A7354ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG1, MSG0, 4);
    MSG2 = _mm_add_epi32(MSG2, TMP);
    MSG2 = _mm_sha256msg2_epu32(MSG2, MSG1);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG0 = _mm_sha256msg1_epu32(MSG0, MSG1);

    MSG = _mm_add_epi32(MSG2, _mm_set_epi64x(0xC76C51A3C24B8B70ULL, 0xA81A664BA2BFE8A1ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG2, MSG1, 4);
    MSG3 = _mm_add_epi32(MSG3, TMP);
    MSG3 = _mm_sha256msg2_epu32(MSG3, MSG2);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG1 = _mm_sha256msg1_epu32(MSG1, MSG2);

    MSG = _mm_add_epi32(MSG3, _mm_set_epi64x(0x106AA070F40E3585ULL, 0xD6990624D192E819ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG3, MSG2, 4);
    MSG0 = _mm_add_epi32(MSG0, TMP);
    MSG0 = _mm_sha256msg2_epu32(MSG0, MSG3);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG2 = _mm_sha256msg1_epu32(MSG2, MSG3);

    MSG = _mm_add_epi32(MSG0, _mm_set_epi64x(0x34B0BCB52748774CULL, 0x1E376C0819A4C116ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG0, MSG3, 4);
    MSG1 = _mm_add_epi32(MSG1, TMP);
    MSG1 = _mm_sha256msg2_epu32(MSG1, MSG0);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);
    MSG3 = _mm_sha256msg1_epu32(MSG3, MSG0);

    MSG = _mm_add_epi32(MSG1, _mm_set_epi64x(0x682E6FF35B9CCA4FULL, 0x4ED8AA4A391C0CB3ULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG1, MSG0, 4);
    MSG2 = _mm_add_epi32(MSG2, TMP);
    MSG2 = _mm_sha256msg2_epu32(MSG2, MSG1);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);

    MSG = _mm_add_epi32(MSG2, _mm_set_epi64x(0x8CC7020884C87814ULL, 0x78A5636F748F82EEULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    TMP = _mm_alignr_epi8(MSG2, MSG1, 4);
    MSG3 = _mm_add_epi32(MSG3, TMP);
    MSG3 = _mm_sha256msg2_epu32(MSG3, MSG2);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);

    MSG = _mm_add_epi32(MSG3, _mm_set_epi64x(0xC67178F2BEF9A3F7ULL, 0xA4506CEB90BEFFFAULL));
    STATE1 = _mm_sha256rnds2_epu32(STATE1, STATE0, MSG);
    MSG = _mm_shuffle_epi32(MSG, 0x0E);
    STATE0 = _mm_sha256rnds2_epu32(STATE0, STATE1, MSG);

    STATE0 = _mm_add_epi32(STATE0, ABEF_SAVE);
    STATE1 = _mm_add_epi32(STATE1, CDGH_SAVE);

    TMP = _mm_shuffle_epi32(STATE0, 0x1B);
    STATE1 = _mm_shuffle_epi32(STATE1, 0xB1);
    STATE0 = _mm_blend_epi16(TMP, STATE1, 0xF0);
    STATE1 = _mm_alignr_epi8(STATE1, TMP, 8);

    _mm_storeu_si128((__m128i*) &state[0], STATE0);
    _mm_storeu_si128((__m128i*) &state[4], STATE1);
}
#endif

static void sha256_block(uint32_t h[8], const uint8_t b[64]) {
#if defined(__SHA__) && defined(__SSSE3__)
    sha256_block_shani(h, b);
#else
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)b[i * 4] << 24) | ((uint32_t)b[i * 4 + 1] << 16) | ((uint32_t)b[i * 4 + 2] << 8) | b[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = hh + S1 + ch + K256[i] + w[i];
        uint32_t S0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22);
        uint32_t maj = (a & bb) ^ (a & c) ^ (bb & c);
        uint32_t t2 = S0 + maj;
        hh = g; g = f; f = e; e = d + t1;
        d = c; c = bb; bb = a; a = t1 + t2;
    }
    h[0] += a; h[1] += bb; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f;  h[6] += g; h[7] += hh;
#endif
}

void sha256_init(sha256_t *s) {
    s->h[0] = 0x6a09e667; s->h[1] = 0xbb67ae85; s->h[2] = 0x3c6ef372; s->h[3] = 0xa54ff53a;
    s->h[4] = 0x510e527f; s->h[5] = 0x9b05688c; s->h[6] = 0x1f83d9ab; s->h[7] = 0x5be0cd19;
    s->bits = 0;
    s->n = 0;
}

void sha256_update(sha256_t *s, const void *data, size_t len) {
    const uint8_t *p = data;
    s->bits += (uint64_t)len * 8;
    while (len > 0) {
        size_t take = 64 - s->n;
        if (take > len) take = len;
        memcpy(s->buf + s->n, p, take);
        s->n += take;
        p += take;
        len -= take;
        if (s->n == 64) {
            sha256_block(s->h, s->buf);
            s->n = 0;
        }
    }
}

void sha256_final(sha256_t *s, uint8_t out[32]) {
    s->buf[s->n++] = 0x80;
    if (s->n > 56) {
        memset(s->buf + s->n, 0, 64 - s->n);
        sha256_block(s->h, s->buf);
        s->n = 0;
    }
    memset(s->buf + s->n, 0, 56 - s->n);
    for (int i = 0; i < 8; i++) s->buf[56 + i] = (uint8_t)(s->bits >> (56 - i * 8));
    sha256_block(s->h, s->buf);
    for (int i = 0; i < 8; i++) {
        out[i * 4]     = (uint8_t)(s->h[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(s->h[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(s->h[i] >> 8);
        out[i * 4 + 3] = (uint8_t)s->h[i];
    }
}

void hmac_key_init(hmac_key_t *k, const void *key, size_t klen) {
    uint8_t kb[64] = {0}, pad[64];
    if (klen > 64) {
        sha256_t s;
        sha256_init(&s);
        sha256_update(&s, key, klen);
        sha256_final(&s, kb);
    } else {
        memcpy(kb, key, klen);
    }
    for (int i = 0; i < 64; i++) pad[i] = kb[i] ^ 0x36;
    sha256_init(&k->in);
    sha256_update(&k->in, pad, 64);
    for (int i = 0; i < 64; i++) pad[i] = kb[i] ^ 0x5c;
    sha256_init(&k->out);
    sha256_update(&k->out, pad, 64);
}

void hmac_sha256_k(const hmac_key_t *k, const void *msg, size_t n, uint8_t out[32]) {
    sha256_t s = k->in;
    uint8_t ih[32];
    sha256_update(&s, msg, n);
    sha256_final(&s, ih);
    s = k->out;
    sha256_update(&s, ih, 32);
    sha256_final(&s, out);
}

void hmac_sha256(const void *key, size_t klen, const void *msg, size_t n, uint8_t out[32]) {
    hmac_key_t k;
    hmac_key_init(&k, key, klen);
    hmac_sha256_k(&k, msg, n, out);
}

static sha256_t hmac_ipad_ctx, hmac_opad_ctx;

void jwt_init(const char *secret) {
    uint8_t key[64] = {0}, ipad[64], opad[64];
    size_t n = strlen(secret);
    if (n > 64) {
        sha256_t s;
        sha256_init(&s);
        sha256_update(&s, secret, n);
        sha256_final(&s, key);
    } else {
        memcpy(key, secret, n);
    }
    for (int i = 0; i < 64; i++) {
        ipad[i] = key[i] ^ 0x36;
        opad[i] = key[i] ^ 0x5c;
    }
    sha256_init(&hmac_ipad_ctx);
    sha256_update(&hmac_ipad_ctx, ipad, 64);
    sha256_init(&hmac_opad_ctx);
    sha256_update(&hmac_opad_ctx, opad, 64);
}

static void jwt_hmac_sha256(const void *msg, size_t len, uint8_t out[32]) {
    uint8_t inner[32];
    sha256_t s = hmac_ipad_ctx;
    sha256_update(&s, msg, len);
    sha256_final(&s, inner);
    s = hmac_opad_ctx;
    sha256_update(&s, inner, 32);
    sha256_final(&s, out);
}

// ---------- base64 / base64url ----------

static const char B64S[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char B64U[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static size_t b64_enc_alpha(char *out, const uint8_t *in, size_t n, const char *al, bool pad) {
    size_t o = 0, i = 0;
    for (; i + 2 < n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8 | (uint32_t)in[i + 2];
        out[o++] = al[v >> 18]; out[o++] = al[(v >> 12) & 63];
        out[o++] = al[(v >> 6) & 63]; out[o++] = al[v & 63];
    }
    if (n - i == 1) {
        uint32_t v = (uint32_t)in[i] << 16;
        out[o++] = al[v >> 18]; out[o++] = al[(v >> 12) & 63];
        if (pad) { out[o++] = '='; out[o++] = '='; }
    } else if (n - i == 2) {
        uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8;
        out[o++] = al[v >> 18]; out[o++] = al[(v >> 12) & 63]; out[o++] = al[(v >> 6) & 63];
        if (pad) out[o++] = '=';
    }
    return o;
}

size_t b64_enc(char *out, const uint8_t *in, size_t n) { return b64_enc_alpha(out, in, n, B64S, true); }
static size_t b64u_enc(char *dst, const uint8_t *src, size_t n) { return b64_enc_alpha(dst, src, n, B64U, false); }

static inline int b64_val(char c, bool url) {
    unsigned char u = (unsigned char)c;
    if (__builtin_expect(u >= 'A' && u <= 'Z', 1)) return (int)(u - 'A');
    if (__builtin_expect(u >= 'a' && u <= 'z', 1)) return (int)(u - 'a' + 26);
    if (__builtin_expect(u >= '0' && u <= '9', 1)) return (int)(u - '0' + 52);
    if (url) {
        if (u == '-') return 62;
        if (u == '_') return 63;
    } else {
        if (u == '+') return 62;
        if (u == '/') return 63;
    }
    return -1;
}

static long b64_dec_alpha(uint8_t *out, const char *in, size_t n, bool url) {
    if (!url) {
        if (n % 4) return -1;
        while (n && in[n - 1] == '=') n--;
    }
    if (n % 4 == 1) return -1;
    size_t o = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        int v = b64_val(in[i], url);
        if (v < 0) return -1;
        acc = acc << 6 | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[o++] = (uint8_t)(acc >> bits);
        }
    }
    return (long)o;
}

long b64_dec(uint8_t *out, const char *in, size_t n) { return b64_dec_alpha(out, in, n, false); }
// Fast table-driven base64url decoder with 4-byte unrolled processing
static const int8_t B64U_LUT[256] = {
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 62, -1, -1,
    52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, -1, -1, -1, -1, -1,
    -1,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
    15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1, 63,
    -1, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
};

static int b64u_dec(uint8_t *dst, const char *src, size_t n) {
    if (n % 4 == 1) return -1;
    size_t i = 0, o = 0;
    while (i + 4 <= n) {
        int8_t v0 = B64U_LUT[(uint8_t)src[i]];
        int8_t v1 = B64U_LUT[(uint8_t)src[i + 1]];
        int8_t v2 = B64U_LUT[(uint8_t)src[i + 2]];
        int8_t v3 = B64U_LUT[(uint8_t)src[i + 3]];
        if (__builtin_expect((v0 | v1 | v2 | v3) < 0, 0)) return -1;
        dst[o++] = (uint8_t)((v0 << 2) | (v1 >> 4));
        dst[o++] = (uint8_t)(((v1 & 15) << 4) | (v2 >> 2));
        dst[o++] = (uint8_t)(((v2 & 3) << 6) | v3);
        i += 4;
    }
    if (n - i == 2) {
        int8_t v0 = B64U_LUT[(uint8_t)src[i]];
        int8_t v1 = B64U_LUT[(uint8_t)src[i + 1]];
        if ((v0 | v1) < 0) return -1;
        dst[o++] = (uint8_t)((v0 << 2) | (v1 >> 4));
    } else if (n - i == 3) {
        int8_t v0 = B64U_LUT[(uint8_t)src[i]];
        int8_t v1 = B64U_LUT[(uint8_t)src[i + 1]];
        int8_t v2 = B64U_LUT[(uint8_t)src[i + 2]];
        if ((v0 | v1 | v2) < 0) return -1;
        dst[o++] = (uint8_t)((v0 << 2) | (v1 >> 4));
        dst[o++] = (uint8_t)(((v1 & 15) << 4) | (v2 >> 2));
    }
    return (int)o;
}

// ---------- JWT HS256 (matching golang-jwt/jwt v5 semantics) ----------

size_t jwt_issue(char *out, int64_t user_id) {
    static const char hdr[] = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.";
    memcpy(out, hdr, sizeof(hdr) - 1);
    size_t pos = sizeof(hdr) - 1;

    int64_t now = (int64_t)time(NULL);
    char pay[128];
    int plen = snprintf(pay, sizeof(pay), "{\"sub\":\"%lld\",\"iat\":%lld,\"exp\":%lld}",
                        (long long)user_id, (long long)now, (long long)(now + 30 * 86400));
    pos += b64u_enc(out + pos, (const uint8_t *)pay, (size_t)plen);

    uint8_t mac[32];
    jwt_hmac_sha256(out, pos, mac);
    out[pos++] = '.';
    pos += b64u_enc(out + pos, mac, 32);
    return pos;
}

static bool claim_num(const jv_t *obj, const char *k, bool required, double *out) {
    jv_t *v = json_get(obj, k);
    if (!v || v->type == J_NULL) return !required;
    if (v->type != J_NUM || !isfinite(v->num)) return false;
    *out = v->num;
    return true;
}

static bool claim_str(const jv_t *obj, const char *k) {
    jv_t *v = json_get(obj, k);
    return !v || v->type == J_NULL || v->type == J_STR;
}

static bool claim_aud(const jv_t *obj) {
    jv_t *v = json_get(obj, "aud");
    if (!v || v->type == J_NULL || v->type == J_STR) return true;
    if (v->type != J_ARR || !v->child) return false;
    for (jv_t *e = v->child; e; e = e->next)
        if (e->type != J_STR) return false;
    return true;
}

bool jwt_verify(arena_t *a, const char *tok, size_t len, int64_t *user_id) {
    if (len == 0 || len > 2048) return false;
    const char *d1 = memchr(tok, '.', len);
    if (!d1) return false;
    size_t rem = len - (size_t)(d1 + 1 - tok);
    const char *d2 = memchr(d1 + 1, '.', rem);
    if (!d2 || memchr(d2 + 1, '.', len - (size_t)(d2 + 1 - tok))) return false;

    size_t hlen = (size_t)(d1 - tok), plen = (size_t)(d2 - (d1 + 1)), slen = len - (size_t)(d2 + 1 - tok);
    if (slen != 43) return false;

    uint8_t sig[36], mac[32];
    if (b64u_dec(sig, d2 + 1, slen) != 32) return false;
    jwt_hmac_sha256(tok, (size_t)(d2 - tok), mac);
    uint8_t diff = 0;
    for (int i = 0; i < 32; i++) diff |= sig[i] ^ mac[i];
    if (diff != 0) return false;

    static const char std_hdr[] = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
    bool std_header_matched = (hlen == sizeof(std_hdr) - 1 && memcmp(tok, std_hdr, sizeof(std_hdr) - 1) == 0);
    if (!std_header_matched) {
        uint8_t *hbuf = arena_alloc(a, hlen + 4);
        int hdec = b64u_dec(hbuf, tok, hlen);
        if (hdec < 0) return false;
        jv_t *hdr = json_parse(a, (const char *)hbuf, (size_t)hdec);
        if (!hdr || hdr->type != J_OBJ) return false;
        jv_t *alg = json_get(hdr, "alg");
        if (!alg || alg->type != J_STR || !str_eq(alg->s, "HS256")) return false;
    }

    uint8_t *pbuf = arena_alloc(a, plen + 4);
    int pdec = b64u_dec(pbuf, d1 + 1, plen);
    if (pdec < 0) return false;
    jv_t *cl = json_parse(a, (const char *)pbuf, (size_t)pdec);
    if (!cl || cl->type != J_OBJ) return false;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;

    double exp = 0, nbf = 0, iat = 0;
    if (!claim_num(cl, "exp", true, &exp) || now >= exp) return false;
    if (!claim_num(cl, "nbf", false, &nbf) || (json_get(cl, "nbf") && json_get(cl, "nbf")->type != J_NULL && now < nbf)) return false;
    if (!claim_num(cl, "iat", false, &iat)) return false;
    if (!claim_str(cl, "iss") || !claim_str(cl, "jti") || !claim_aud(cl)) return false;

    jv_t *sub = json_get(cl, "sub");
    if (!sub || sub->type != J_STR) return false;
    int64_t id = 0;
    if (!parse_uint(sub->s.p, sub->s.n, &id) || id <= 0) return false;
    *user_id = id;
    return true;
}
