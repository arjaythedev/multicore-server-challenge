// bcrypt ($2a$ / $2b$ / $2y$), computing up to BC_LANES hashes at once in one thread.
//
// A bcrypt hash is ~1.07 million Blowfish block encryptions, each a chain of dependent table lookups, so a
// single hash keeps the CPU waiting on load latency and leaves most execution units idle. Interleaving the
// encryptions of several independent hashes (the lanes) overlaps those chains: same work per hash, more hashes
// per second per core. Every hash is still full bcrypt at the stored cost, and every login is verified
// against its stored hash; only the scheduling differs. Checked against libxcrypt by `conduit --bcrypt-selftest`.
#include "conduit.h"
#include "bf_pi.h"
#include <sys/random.h>

typedef struct { uint32_t P[18]; uint32_t S[4][256]; } bf_t;

#define F(st, x) ((((st)->S[0][(x) >> 24] + (st)->S[1][((x) >> 16) & 0xff]) ^ (st)->S[2][((x) >> 8) & 0xff]) + \
                  (st)->S[3][(x) & 0xff])

// One Blowfish block per lane.
static inline __attribute__((always_inline)) void enc(int N, bf_t *st, uint32_t *L, uint32_t *R) {
    for (int l = 0; l < N; l++) L[l] ^= st[l].P[0];
    for (int r = 1; r < 17; r += 2) {
        for (int l = 0; l < N; l++) R[l] ^= F(&st[l], L[l]) ^ st[l].P[r];
        for (int l = 0; l < N; l++) L[l] ^= F(&st[l], R[l]) ^ st[l].P[r + 1];
    }
    for (int l = 0; l < N; l++) {
        uint32_t t = L[l];
        L[l] = R[l] ^ st[l].P[17];
        R[l] = t;
    }
}

// Blowfish key expansion: P ^= key words, then re-encrypt the whole state in place. With salt words (sw),
// each block is first XORed with the salt stream (the "expandstate" of the first round); without, it's
// "expand0state".
static inline __attribute__((always_inline)) void expand(int N, bf_t *st, const uint32_t (*kw)[18],
                                                         const uint32_t (*sw)[4]) {
    uint32_t L[N], R[N];
    for (int l = 0; l < N; l++) {
        for (int i = 0; i < 18; i++) st[l].P[i] ^= kw[l][i];
        L[l] = R[l] = 0;
    }
    for (int i = 0; i < 18; i += 2) {
        if (sw)
            for (int l = 0; l < N; l++) L[l] ^= sw[l][i & 3], R[l] ^= sw[l][(i + 1) & 3];
        enc(N, st, L, R);
        for (int l = 0; l < N; l++) st[l].P[i] = L[l], st[l].P[i + 1] = R[l];
    }
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < 256; i += 2) {
            if (sw) {
                int w = 18 + b * 256 + i; // position in the salt word stream, continuing after P
                for (int l = 0; l < N; l++) L[l] ^= sw[l][w & 3], R[l] ^= sw[l][(w + 1) & 3];
            }
            enc(N, st, L, R);
            for (int l = 0; l < N; l++) st[l].S[b][i] = L[l], st[l].S[b][i + 1] = R[l];
        }
}

// EksBlowfish + the 64x "OrpheanBeholderScryDoubt" encryption; out gets the 24 ciphertext bytes per lane.
static inline __attribute__((always_inline)) void eks(int N, const uint32_t (*kw)[18], const uint32_t (*sw)[4],
                                                      int cost, uint8_t (*out)[24]) {
    bf_t st[N];
    uint32_t ss[N][18], c[N][6];
    for (int l = 0; l < N; l++) {
        memcpy(st[l].P, BF_P0, sizeof BF_P0);
        memcpy(st[l].S, BF_S0, sizeof BF_S0);
        for (int i = 0; i < 18; i++) ss[l][i] = sw[l][i & 3]; // the 16-byte salt as a cycled key
    }
    expand(N, st, kw, sw);
    for (uint64_t r = 0; r < (1ull << cost); r++) {
        expand(N, st, kw, NULL);
        expand(N, st, (const uint32_t(*)[18])ss, NULL);
    }
    static const uint32_t ORPHEAN[6] = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
    for (int l = 0; l < N; l++) memcpy(c[l], ORPHEAN, sizeof ORPHEAN);
    for (int k = 0; k < 64; k++)
        for (int j = 0; j < 6; j += 2) {
            uint32_t L[N], R[N];
            for (int l = 0; l < N; l++) L[l] = c[l][j], R[l] = c[l][j + 1];
            enc(N, st, L, R);
            for (int l = 0; l < N; l++) c[l][j] = L[l], c[l][j + 1] = R[l];
        }
    for (int l = 0; l < N; l++)
        for (int j = 0; j < 6; j++) {
            out[l][4 * j] = c[l][j] >> 24;
            out[l][4 * j + 1] = c[l][j] >> 16;
            out[l][4 * j + 2] = c[l][j] >> 8;
            out[l][4 * j + 3] = c[l][j];
        }
}

#define EKS_N(n) \
    static __attribute__((noinline)) void eks##n(const uint32_t (*kw)[18], const uint32_t (*sw)[4], int cost, \
                                                 uint8_t (*out)[24]) { eks(n, kw, sw, cost, out); }
EKS_N(1)
EKS_N(2)
EKS_N(3)
EKS_N(4)

// ---------- bcrypt's base64 and setting strings ----------

static const char BB64[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static void bb64_enc(char *o, const uint8_t *p, size_t n) {
    const uint8_t *e = p + n;
    while (p < e) {
        unsigned c1 = *p++;
        *o++ = BB64[c1 >> 2];
        c1 = (c1 & 3) << 4;
        if (p >= e) { *o++ = BB64[c1]; break; }
        unsigned c2 = *p++;
        *o++ = BB64[c1 | c2 >> 4];
        c1 = (c2 & 15) << 2;
        if (p >= e) { *o++ = BB64[c1]; break; }
        c2 = *p++;
        *o++ = BB64[c1 | c2 >> 6];
        *o++ = BB64[c2 & 63];
    }
    *o = 0;
}

static int bb64v(char c) {
    const char *p = c ? strchr(BB64, c) : NULL;
    return p ? (int)(p - BB64) : -1;
}

static bool bb64_dec16(uint8_t out[16], const char *s) { // 22 chars -> 16 bytes
    int o = 0;
    for (int i = 0; i < 22 && o < 16; i += 4) {
        int c1 = bb64v(s[i]), c2 = bb64v(s[i + 1]);
        if (c1 < 0 || c2 < 0) return false;
        out[o++] = c1 << 2 | c2 >> 4;
        if (o == 16) break;
        int c3 = bb64v(s[i + 2]);
        if (c3 < 0) return false;
        out[o++] = (c2 & 15) << 4 | c3 >> 2;
        int c4 = bb64v(s[i + 3]);
        if (c4 < 0) return false;
        out[o++] = (c3 & 3) << 6 | c4;
    }
    return true;
}

// "$2b$10$" + 22 salt chars [+ 31 hash chars]: salt words and cost; false for anything else.
static bool parse_setting(const char *s, int *cost, uint32_t sw[4]) {
    if (s[0] != '$' || s[1] != '2' || (s[2] != 'a' && s[2] != 'b' && s[2] != 'y') || s[3] != '$') return false;
    if (s[4] < '0' || s[4] > '3' || s[5] < '0' || s[5] > '9' || s[6] != '$') return false;
    *cost = (s[4] - '0') * 10 + (s[5] - '0');
    if (*cost < 4 || *cost > 31 || strnlen(s + 7, 22) < 22) return false;
    uint8_t salt[16];
    if (!bb64_dec16(salt, s + 7)) return false;
    for (int i = 0; i < 4; i++)
        sw[i] = (uint32_t)salt[4 * i] << 24 | (uint32_t)salt[4 * i + 1] << 16 | (uint32_t)salt[4 * i + 2] << 8 | salt[4 * i + 3];
    return true;
}

// The key stream: the password and its NUL, repeated, as 18 big-endian words (passwords are <= 72 bytes).
static void key_words(const char *pw, uint32_t kw[18]) {
    size_t n = strlen(pw) + 1, j = 0;
    for (int i = 0; i < 18; i++) {
        uint32_t w = 0;
        for (int k = 0; k < 4; k++) {
            w = w << 8 | (uint8_t)pw[j];
            j = j + 1 == n ? 0 : j + 1;
        }
        kw[i] = w;
    }
}

bool bc_gensalt(char setting[30]) {
    uint8_t r[16];
    if (getrandom(r, sizeof r, 0) != sizeof r) return false;
    memcpy(setting, "$2b$10$", 7);
    bb64_enc(setting + 7, r, 16);
    return true;
}

// Computes n (1..BC_LANES) hashes; all settings must parse and share one cost (bc_compatible). out[l] gets the
// full 60-char hash string: the setting's prefix and salt, then the 31-char hash.
void bc_hash_n(int n, const char *const *pw, const char *const *setting, char (*out)[64]) {
    uint32_t kw[BC_LANES][18], sw[BC_LANES][4];
    uint8_t ct[BC_LANES][24];
    int cost = 0;
    for (int l = 0; l < n; l++) {
        parse_setting(setting[l], &cost, sw[l]);
        key_words(pw[l], kw[l]);
    }
    switch (n) {
    case 1: eks1((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    case 2: eks2((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    case 3: eks3((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    default: eks4((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    }
    for (int l = 0; l < n; l++) {
        memcpy(out[l], setting[l], 29); // "$2b$10$" + 22 salt chars, as given
        bb64_enc(out[l] + 29, ct[l], 23);
    }
}

// The cost of a setting this implementation handles, or -1 (then libxcrypt does it).
int bc_cost(const char *setting) {
    int cost;
    uint32_t sw[4];
    return parse_setting(setting, &cost, sw) ? cost : -1;
}
