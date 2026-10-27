/* bcrypt over several independent hashes at once. One bcrypt is a single dependency chain: every Blowfish round
 * waits for its S-box loads, so a core running one hash sits mostly idle. Running N hashes in lockstep in one
 * loop gives the core N independent chains to overlap, for close to N times the throughput until the load ports
 * saturate. The lane count is a compile-time constant in each kernel, so the lane loops unroll completely.
 *
 * Bit for bit the same result as bcrypt_raw (tests/unit.c checks every lane against it). */
#include "bcrypt.h"

#include "bf_init.h"

#define AI static inline __attribute__((always_inline))

struct bf {
    uint32_t P[18];
    uint32_t S[4][256];
};

#define F(st, x) \
    ((((st)->S[0][(x) >> 24] + (st)->S[1][(x) >> 16 & 0xff]) ^ (st)->S[2][(x) >> 8 & 0xff]) + (st)->S[3][(x) & 0xff])

/* One Blowfish encryption in each lane. */
AI void enc(struct bf *st, uint32_t *l, uint32_t *r, const int n) {
    for (int k = 0; k < n; k++) l[k] ^= st[k].P[0];
    for (int i = 1; i <= 16; i += 2) {
        for (int k = 0; k < n; k++) r[k] ^= F(&st[k], l[k]) ^ st[k].P[i];
        for (int k = 0; k < n; k++) l[k] ^= F(&st[k], r[k]) ^ st[k].P[i + 1];
    }
    for (int k = 0; k < n; k++) {
        uint32_t t = r[k] ^ st[k].P[17];
        r[k] = l[k];
        l[k] = t;
    }
}

/* ExpandKey(state, 0, key) with the key already as its 18 cyclic words. */
AI void expand(struct bf *st, const uint32_t (*w)[18], const int n) {
    uint32_t l[BCRYPT_LANES_MAX] = {0}, r[BCRYPT_LANES_MAX] = {0};
    for (int k = 0; k < n; k++)
        for (int i = 0; i < 18; i++) st[k].P[i] ^= w[k][i];
    for (int i = 0; i < 18; i += 2) {
        enc(st, l, r, n);
        for (int k = 0; k < n; k++) st[k].P[i] = l[k], st[k].P[i + 1] = r[k];
    }
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < 256; i += 2) {
            enc(st, l, r, n);
            for (int k = 0; k < n; k++) st[k].S[b][i] = l[k], st[k].S[b][i + 1] = r[k];
        }
}

/* ExpandKey(state, salt, key): as expand, but each block is first XORed with the next two salt words. */
AI void expand_salted(struct bf *st, const uint32_t (*kw)[18], const uint32_t (*sw)[18], const int n) {
    uint32_t l[BCRYPT_LANES_MAX] = {0}, r[BCRYPT_LANES_MAX] = {0};
    int j = 0;  /* salt word index; the salt is 4 words, so the stream repeats every 4 */
    for (int k = 0; k < n; k++)
        for (int i = 0; i < 18; i++) st[k].P[i] ^= kw[k][i];
    for (int i = 0; i < 18; i += 2, j += 2) {
        for (int k = 0; k < n; k++) l[k] ^= sw[k][j & 3], r[k] ^= sw[k][(j + 1) & 3];
        enc(st, l, r, n);
        for (int k = 0; k < n; k++) st[k].P[i] = l[k], st[k].P[i + 1] = r[k];
    }
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < 256; i += 2, j += 2) {
            for (int k = 0; k < n; k++) l[k] ^= sw[k][j & 3], r[k] ^= sw[k][(j + 1) & 3];
            enc(st, l, r, n);
            for (int k = 0; k < n; k++) st[k].S[b][i] = l[k], st[k].S[b][i + 1] = r[k];
        }
}

/* The 18 big-endian words of a byte string used cyclically. */
static void cyclic_words(const uint8_t *data, size_t len, uint32_t w[18]) {
    size_t pos = 0;
    for (int i = 0; i < 18; i++) {
        uint32_t x = 0;
        for (int b = 0; b < 4; b++) {
            x = x << 8 | data[pos];
            if (++pos == len) pos = 0;
        }
        w[i] = x;
    }
}

AI void kernel(const struct bcrypt_lane *in, int cost, uint8_t (*out)[BCRYPT_RAW], const int n) {
    struct bf st[BCRYPT_LANES_MAX];
    uint32_t kw[BCRYPT_LANES_MAX][18], sw[BCRYPT_LANES_MAX][18];
    for (int k = 0; k < n; k++) {
        uint8_t key[BCRYPT_MAX_PW + 1];
        size_t len = in[k].pwlen > BCRYPT_MAX_PW ? BCRYPT_MAX_PW : in[k].pwlen;
        memcpy(key, in[k].pw, len);
        key[len] = 0;
        cyclic_words(key, len + 1, kw[k]);
        cyclic_words(in[k].salt, BCRYPT_SALT, sw[k]);
        memcpy(st[k].P, bf_init_P, sizeof st[k].P);
        memcpy(st[k].S, bf_init_S, sizeof st[k].S);
    }
    expand_salted(st, kw, sw, n);
    for (uint64_t i = (uint64_t)1 << cost; i; i--) {
        expand(st, kw, n);
        expand(st, sw, n);
    }

    static const char magic[24] = "OrpheanBeholderScryDoubt";
    uint32_t c[6][BCRYPT_LANES_MAX];
    for (int i = 0; i < 6; i++)
        for (int k = 0; k < n; k++) c[i][k] = load_be32(magic + 4 * i);
    for (int m = 0; m < 64; m++)
        for (int i = 0; i < 6; i += 2) enc(st, c[i], c[i + 1], n);
    for (int k = 0; k < n; k++) {
        uint8_t full[24];
        for (int i = 0; i < 6; i++) store_be32(full + 4 * i, c[i][k]);
        memcpy(out[k], full, BCRYPT_RAW);
    }
}

__attribute__((noinline)) static void kernel1(const struct bcrypt_lane *in, int cost, uint8_t (*out)[BCRYPT_RAW]) {
    kernel(in, cost, out, 1);
}
__attribute__((noinline)) static void kernel2(const struct bcrypt_lane *in, int cost, uint8_t (*out)[BCRYPT_RAW]) {
    kernel(in, cost, out, 2);
}
__attribute__((noinline)) static void kernel4(const struct bcrypt_lane *in, int cost, uint8_t (*out)[BCRYPT_RAW]) {
    kernel(in, cost, out, 4);
}
__attribute__((noinline)) static void kernel8(const struct bcrypt_lane *in, int cost, uint8_t (*out)[BCRYPT_RAW]) {
    kernel(in, cost, out, 8);
}

void bcrypt_raw_lanes(const struct bcrypt_lane *in, int n, int cost, uint8_t (*out)[BCRYPT_RAW]) {
    if (n == 3) {
        /* Three hashes in the 4-lane kernel with the first repeated (about 60 ms) beat 2 + 1 lanes (about 92). */
        struct bcrypt_lane pad[4] = {in[0], in[1], in[2], in[0]};
        uint8_t tmp[4][BCRYPT_RAW];
        kernel4(pad, cost, tmp);
        memcpy(out, tmp, 3 * sizeof tmp[0]);
        return;
    }
    while (n > 0) {
        int k = n >= 8 && BCRYPT_LANES_MAX >= 8 ? 8 : n >= 4 ? 4 : n >= 2 ? 2 : 1;
        if (k == 8) kernel8(in, cost, out);
        else if (k == 4) kernel4(in, cost, out);
        else if (k == 2) kernel2(in, cost, out);
        else kernel1(in, cost, out);
        in += k, out += k, n -= k;
    }
}
