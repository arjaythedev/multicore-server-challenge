#include "sha256.h"

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static inline uint32_t ror(uint32_t x, int n) { return x >> n | x << (32 - n); }

void sha256_blocks_generic(uint32_t h[8], const uint8_t *p, size_t n) {
    uint32_t w[64];
    for (; n; n--, p += 64) {
        for (int i = 0; i < 16; i++) w[i] = load_be32(p + 4 * i);
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t t1 = hh + (ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
            uint32_t t2 = (ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
            hh = g, g = f, f = e, e = d + t1, d = c, c = b, b = a, a = t1 + t2;
        }
        h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e, h[5] += f, h[6] += g, h[7] += hh;
    }
}

sha256_blocks_fn sha256_blocks = sha256_blocks_generic;

void sha256_select(void) {
    /* The SHA-NI block function arrives with the app-side CPU work (plan M9). */
    sha256_blocks = sha256_blocks_generic;
}

void sha256_init(struct sha256 *s) {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, iv, sizeof iv);
    s->total = 0;
    s->blen = 0;
}

void sha256_update(struct sha256 *s, const void *data, size_t n) {
    const uint8_t *p = data;
    s->total += n;
    if (s->blen) {
        size_t take = SHA256_BLOCK - s->blen;
        if (take > n) take = n;
        memcpy(s->blk + s->blen, p, take);
        s->blen += take, p += take, n -= take;
        if (s->blen < SHA256_BLOCK) return;
        sha256_blocks(s->h, s->blk, 1);
        s->blen = 0;
    }
    if (n >= SHA256_BLOCK) {
        sha256_blocks(s->h, p, n / SHA256_BLOCK);
        p += n & ~(size_t)(SHA256_BLOCK - 1);
        n &= SHA256_BLOCK - 1;
    }
    memcpy(s->blk, p, n);
    s->blen = n;
}

void sha256_final(struct sha256 *s, uint8_t out[SHA256_LEN]) {
    uint64_t bits = s->total * 8;
    s->blk[s->blen++] = 0x80;
    if (s->blen > SHA256_BLOCK - 8) {
        memset(s->blk + s->blen, 0, SHA256_BLOCK - s->blen);
        sha256_blocks(s->h, s->blk, 1);
        s->blen = 0;
    }
    memset(s->blk + s->blen, 0, SHA256_BLOCK - 8 - s->blen);
    store_be64(s->blk + SHA256_BLOCK - 8, bits);
    sha256_blocks(s->h, s->blk, 1);
    for (int i = 0; i < 8; i++) store_be32(out + 4 * i, s->h[i]);
}

void sha256(const void *data, size_t n, uint8_t out[SHA256_LEN]) {
    struct sha256 s;
    sha256_init(&s);
    sha256_update(&s, data, n);
    sha256_final(&s, out);
}
