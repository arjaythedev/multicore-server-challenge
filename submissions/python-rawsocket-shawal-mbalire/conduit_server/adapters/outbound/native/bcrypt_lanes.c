/* bcrypt ($2a$/$2b$/$2y$, OpenBSD's algorithm) for several passwords at once.
 *
 * The cost is the key schedule: 2 * 2^cost expansions of 521 Blowfish encryptions each, every encryption 16
 * rounds of dependent S-box lookups. One hash is one long dependency chain, so a core mostly waits on loads.
 * N hashes run in lockstep (each round does all lanes' lookups before any lane's next round) let those waits
 * overlap: the same work, more of it in flight.
 *
 *   int bcrypt_many(int n, const char *const *pw, const char *const *setting, char *out)
 *
 * pw[i]: NUL-terminated password (at most 72 bytes are used, as bcrypt does); setting[i]: "$2b$10$" + 22 salt
 * chars (a full hash works too, the rest is ignored). out: n * 61 bytes, each a NUL-terminated 60-char hash.
 * Returns 0, or -1 if any setting is malformed (nothing is written then).
 * Built by build.sh (gcc); the Python side is crypto_adapter.bcrypt_many.
 */
#include <stdint.h>
#include <string.h>

#include "bf_init.h"

typedef struct {
    uint32_t P[18];
    uint32_t S[4][256];
} bf_state;

static const char B64[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static int b64_index(char c) {
    const char *p = c ? strchr(B64, c) : NULL;
    return p ? (int)(p - B64) : -1;
}

/* bcrypt's base64 (no padding): decode exactly `n` bytes from `src` */
static int b64_decode(uint8_t *dst, int n, const char *src) {
    int bits = 0, acc = 0, o = 0;
    while (o < n) {
        int v = b64_index(*src++);
        if (v < 0)
            return -1;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            dst[o++] = (uint8_t)(acc >> bits);
        }
    }
    return 0;
}

static void b64_encode(char *dst, const uint8_t *src, int n) {
    int i = 0;
    while (i < n) {
        uint32_t c1 = src[i++];
        *dst++ = B64[c1 >> 2];
        c1 = (c1 & 0x03) << 4;
        if (i >= n) {
            *dst++ = B64[c1];
            break;
        }
        uint32_t c2 = src[i++];
        c1 |= c2 >> 4;
        *dst++ = B64[c1];
        c1 = (c2 & 0x0f) << 2;
        if (i >= n) {
            *dst++ = B64[c1];
            break;
        }
        c2 = src[i++];
        c1 |= c2 >> 6;
        *dst++ = B64[c1];
        *dst++ = B64[c2 & 0x3f];
    }
    *dst = 0;
}

/* `count` big-endian words from `data` read cyclically (bcrypt's stream2word) */
static void stream_words(uint32_t *w, int count, const uint8_t *data, int len) {
    int j = 0;
    for (int i = 0; i < count; i++) {
        uint32_t x = 0;
        for (int b = 0; b < 4; b++) {
            if (j >= len)
                j = 0;
            x = (x << 8) | data[j++];
        }
        w[i] = x;
    }
}

#define F(st, x) \
    ((((st)->S[0][(x) >> 24] + (st)->S[1][((x) >> 16) & 0xff]) ^ (st)->S[2][((x) >> 8) & 0xff]) + \
     (st)->S[3][(x) & 0xff])

static inline void encipher1(const bf_state *st, uint32_t *xl, uint32_t *xr) {
    uint32_t l = *xl ^ st->P[0], r = *xr;
    for (int i = 1; i <= 16; i += 2) {
        r ^= F(st, l) ^ st->P[i];
        l ^= F(st, r) ^ st->P[i + 1];
    }
    *xl = r ^ st->P[17];
    *xr = l;
}

/* Blowfish_expandstate: P ^= key; then encrypt the running block, xored with the salt stream, through P and S */
static void expand_state(bf_state *st, const uint32_t *saltw, const uint32_t *keyw) {
    for (int i = 0; i < 18; i++)
        st->P[i] ^= keyw[i];
    uint32_t l = 0, r = 0;
    int j = 0;
    for (int i = 0; i < 18; i += 2) {
        l ^= saltw[j];
        r ^= saltw[j + 1];
        j = (j + 2) & 3;
        encipher1(st, &l, &r);
        st->P[i] = l;
        st->P[i + 1] = r;
    }
    for (int s = 0; s < 4; s++)
        for (int i = 0; i < 256; i += 2) {
            l ^= saltw[j];
            r ^= saltw[j + 1];
            j = (j + 2) & 3;
            encipher1(st, &l, &r);
            st->S[s][i] = l;
            st->S[s][i + 1] = r;
        }
}

/* L lanes in lockstep: Blowfish_expand0state (P ^= words, then encrypt the running block through P and S), for
 * every lane, each round interleaved across lanes. */
#define DEF_LANES(L)                                                                                     \
    static inline void encipher_##L(bf_state *st, uint32_t *xl, uint32_t *xr) {                         \
        uint32_t l[L], r[L];                                                                             \
        _Pragma("GCC unroll 8") for (int k = 0; k < L; k++) {                                            \
            l[k] = xl[k] ^ st[k].P[0];                                                                   \
            r[k] = xr[k];                                                                                \
        }                                                                                                \
        _Pragma("GCC unroll 16") for (int i = 1; i <= 16; i += 2) {                                      \
            _Pragma("GCC unroll 8") for (int k = 0; k < L; k++) r[k] ^= F(&st[k], l[k]) ^ st[k].P[i];    \
            _Pragma("GCC unroll 8") for (int k = 0; k < L; k++) l[k] ^= F(&st[k], r[k]) ^ st[k].P[i + 1]; \
        }                                                                                                \
        _Pragma("GCC unroll 8") for (int k = 0; k < L; k++) {                                            \
            xl[k] = r[k] ^ st[k].P[17];                                                                  \
            xr[k] = l[k];                                                                                \
        }                                                                                                \
    }                                                                                                    \
    static void expand0_##L(bf_state *st, uint32_t (*words)[18]) {                                       \
        uint32_t xl[L], xr[L];                                                                           \
        for (int k = 0; k < L; k++) {                                                                    \
            for (int i = 0; i < 18; i++)                                                                 \
                st[k].P[i] ^= words[k][i];                                                               \
            xl[k] = xr[k] = 0;                                                                           \
        }                                                                                                \
        for (int i = 0; i < 18; i += 2) {                                                                \
            encipher_##L(st, xl, xr);                                                                    \
            for (int k = 0; k < L; k++) {                                                                \
                st[k].P[i] = xl[k];                                                                      \
                st[k].P[i + 1] = xr[k];                                                                  \
            }                                                                                            \
        }                                                                                                \
        for (int s = 0; s < 4; s++)                                                                      \
            for (int i = 0; i < 256; i += 2) {                                                           \
                encipher_##L(st, xl, xr);                                                                \
                for (int k = 0; k < L; k++) {                                                            \
                    st[k].S[s][i] = xl[k];                                                               \
                    st[k].S[s][i + 1] = xr[k];                                                           \
                }                                                                                        \
            }                                                                                            \
    }                                                                                                    \
    static void rounds_##L(bf_state *st, uint32_t (*keyw)[18], uint32_t (*saltw)[18], uint32_t n) {      \
        for (uint32_t i = 0; i < n; i++) {                                                               \
            expand0_##L(st, keyw);                                                                       \
            expand0_##L(st, saltw);                                                                      \
        }                                                                                                \
    }

DEF_LANES(1)
DEF_LANES(2)
DEF_LANES(3)
DEF_LANES(4)
DEF_LANES(5)
DEF_LANES(6)
DEF_LANES(7)
DEF_LANES(8)

#define MAX_LANES 8

typedef void (*rounds_fn)(bf_state *, uint32_t (*)[18], uint32_t (*)[18], uint32_t);
static const rounds_fn ROUNDS[MAX_LANES + 1] = {0,          rounds_1, rounds_2, rounds_3, rounds_4,
                                                rounds_5,   rounds_6, rounds_7, rounds_8};

typedef struct {
    char prefix[8]; /* "$2b$10$" */
    int cost;
    uint8_t salt[16];
    char salt_b64[23];
    uint8_t key[73];
    int key_len;
} job;

static int parse(job *jb, const char *pw, const char *setting) {
    if (setting[0] != '$' || setting[1] != '2' || (setting[2] != 'a' && setting[2] != 'b' && setting[2] != 'y') ||
        setting[3] != '$' || setting[4] < '0' || setting[4] > '3' || setting[5] < '0' || setting[5] > '9' ||
        setting[6] != '$')
        return -1;
    jb->cost = (setting[4] - '0') * 10 + (setting[5] - '0');
    if (jb->cost < 4 || jb->cost > 31)
        return -1;
    memcpy(jb->prefix, setting, 7);
    jb->prefix[7] = 0;
    if (strlen(setting) < 7 + 22 || b64_decode(jb->salt, 16, setting + 7) != 0)
        return -1;
    /* the 22nd character carries 4 unused bits; re-encode so the output's salt is canonical, as libxcrypt does */
    b64_encode(jb->salt_b64, jb->salt, 16);
    size_t n = strlen(pw);
    /* the key includes the terminating NUL, and bcrypt uses at most 72 bytes of it */
    if (n > 72)
        n = 72;
    memcpy(jb->key, pw, n);
    jb->key[n] = 0;
    jb->key_len = n + 1 > 72 ? 72 : (int)n + 1;
    return 0;
}

static void run_group(job *jb, int L, char *out) {
    bf_state st[MAX_LANES];
    uint32_t keyw[MAX_LANES][18], saltw[MAX_LANES][18];
    for (int k = 0; k < L; k++) {
        memcpy(st[k].P, BF_INIT, sizeof st[k].P);
        memcpy(st[k].S, BF_INIT + 18, sizeof st[k].S);
        stream_words(keyw[k], 18, jb[k].key, jb[k].key_len);
        stream_words(saltw[k], 18, jb[k].salt, 16);
        expand_state(&st[k], saltw[k], keyw[k]);
    }
    ROUNDS[L](st, keyw, saltw, 1u << jb[0].cost);
    for (int k = 0; k < L; k++) {
        static const uint8_t magic[25] = "OrpheanBeholderScryDoubt";
        uint32_t c[6];
        stream_words(c, 6, magic, 24);
        for (int i = 0; i < 64; i++)
            for (int b = 0; b < 6; b += 2)
                encipher1(&st[k], &c[b], &c[b + 1]);
        uint8_t ct[24];
        for (int i = 0; i < 6; i++) {
            ct[4 * i] = c[i] >> 24;
            ct[4 * i + 1] = c[i] >> 16;
            ct[4 * i + 2] = c[i] >> 8;
            ct[4 * i + 3] = c[i];
        }
        char *o = out + 61 * k;
        memcpy(o, jb[k].prefix, 7);
        memcpy(o + 7, jb[k].salt_b64, 22);
        b64_encode(o + 29, ct, 23); /* bcrypt keeps 23 of the 24 bytes */
    }
    memset(st, 0, sizeof st);
    memset(keyw, 0, sizeof keyw);
}

int bcrypt_many(int n, const char *const *pw, const char *const *setting, char *out) {
    if (n < 0)
        return -1;
    job jobs[MAX_LANES];
    for (int i = 0; i < n; i++) /* validate every setting first, so a bad one leaves `out` untouched */
        if (parse(&jobs[0], pw[i], setting[i]) != 0)
            return -1;
    for (int i = 0; i < n;) {
        /* the next run of up to MAX_LANES jobs with the same cost runs as one group */
        int L = 0;
        while (i + L < n && L < MAX_LANES) {
            if (parse(&jobs[L], pw[i + L], setting[i + L]) != 0)
                return -1;
            if (L > 0 && jobs[L].cost != jobs[0].cost)
                break;
            L++;
        }
        run_group(jobs, L, out + 61 * i);
        i += L;
    }
    memset(jobs, 0, sizeof jobs);
    return 0;
}
