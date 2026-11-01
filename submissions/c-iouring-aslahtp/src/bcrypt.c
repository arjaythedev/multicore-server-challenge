#include "bcrypt.h"

#include "bf_init.h"

struct bf {
    uint32_t P[18];
    uint32_t S[4][256];
};

#define F(st, x) \
    ((((st)->S[0][(x) >> 24] + (st)->S[1][(x) >> 16 & 0xff]) ^ (st)->S[2][(x) >> 8 & 0xff]) + (st)->S[3][(x) & 0xff])

static inline void bf_encrypt(const struct bf *st, uint32_t *lp, uint32_t *rp) {
    uint32_t l = *lp, r = *rp;
    l ^= st->P[0];
    for (int i = 1; i <= 16; i += 2) {
        r ^= F(st, l) ^ st->P[i];
        l ^= F(st, r) ^ st->P[i + 1];
    }
    *lp = r ^ st->P[17];
    *rp = l;
}

/* The next 4 bytes of a cyclic byte stream, big-endian. */
static inline uint32_t stream_word(const uint8_t *data, size_t n, size_t *pos) {
    uint32_t w = 0;
    for (int i = 0; i < 4; i++) {
        w = w << 8 | data[*pos];
        if (++*pos == n) *pos = 0;
    }
    return w;
}

/* Blowfish key schedule mixing in a salt (bcrypt's "ExpandKey(state, salt, key)"). */
static void expand_salted(struct bf *st, const uint8_t *key, size_t keylen, const uint8_t salt[BCRYPT_SALT]) {
    size_t kp = 0, sp = 0;
    uint32_t l = 0, r = 0;
    for (int i = 0; i < 18; i++) st->P[i] ^= stream_word(key, keylen, &kp);
    for (int i = 0; i < 18; i += 2) {
        l ^= stream_word(salt, BCRYPT_SALT, &sp);
        r ^= stream_word(salt, BCRYPT_SALT, &sp);
        bf_encrypt(st, &l, &r);
        st->P[i] = l, st->P[i + 1] = r;
    }
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < 256; i += 2) {
            l ^= stream_word(salt, BCRYPT_SALT, &sp);
            r ^= stream_word(salt, BCRYPT_SALT, &sp);
            bf_encrypt(st, &l, &r);
            st->S[b][i] = l, st->S[b][i + 1] = r;
        }
}

/* The plain Blowfish key schedule ("ExpandKey(state, 0, key)"). */
static void expand(struct bf *st, const uint8_t *key, size_t keylen) {
    size_t kp = 0;
    uint32_t l = 0, r = 0;
    for (int i = 0; i < 18; i++) st->P[i] ^= stream_word(key, keylen, &kp);
    for (int i = 0; i < 18; i += 2) {
        bf_encrypt(st, &l, &r);
        st->P[i] = l, st->P[i + 1] = r;
    }
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < 256; i += 2) {
            bf_encrypt(st, &l, &r);
            st->S[b][i] = l, st->S[b][i + 1] = r;
        }
}

void bcrypt_raw(const char *pw, size_t pwlen, const uint8_t salt[BCRYPT_SALT], int cost, uint8_t out[BCRYPT_RAW]) {
    uint8_t key[BCRYPT_MAX_PW + 1];
    struct bf st;
    if (pwlen > BCRYPT_MAX_PW) pwlen = BCRYPT_MAX_PW;
    memcpy(key, pw, pwlen);
    key[pwlen] = 0;
    size_t keylen = pwlen + 1;

    memcpy(st.P, bf_init_P, sizeof st.P);
    memcpy(st.S, bf_init_S, sizeof st.S);
    expand_salted(&st, key, keylen, salt);
    for (uint64_t i = (uint64_t)1 << cost; i; i--) {
        expand(&st, key, keylen);
        expand(&st, salt, BCRYPT_SALT);
    }

    static const char magic[24] = "OrpheanBeholderScryDoubt";
    uint32_t c[6];
    for (int i = 0; i < 6; i++) c[i] = load_be32(magic + 4 * i);
    for (int k = 0; k < 64; k++)
        for (int i = 0; i < 6; i += 2) bf_encrypt(&st, &c[i], &c[i + 1]);
    uint8_t full[24];
    for (int i = 0; i < 6; i++) store_be32(full + 4 * i, c[i]);
    memcpy(out, full, BCRYPT_RAW);
}

static const char alphabet[64] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

size_t bcrypt_b64_encode(char *dst, const uint8_t *src, size_t n) {
    char *d = dst;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)src[i] << 16;
        if (i + 1 < n) v |= (uint32_t)src[i + 1] << 8;
        if (i + 2 < n) v |= src[i + 2];
        *d++ = alphabet[v >> 18];
        *d++ = alphabet[v >> 12 & 63];
        if (i + 1 < n) *d++ = alphabet[v >> 6 & 63];
        if (i + 2 < n) *d++ = alphabet[v & 63];
    }
    return (size_t)(d - dst);
}

static int b64_index(char c) {
    if (c == '.') return 0;
    if (c == '/') return 1;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 2;
    if (c >= 'a' && c <= 'z') return c - 'a' + 28;
    if (c >= '0' && c <= '9') return c - '0' + 54;
    return -1;
}

/* Decodes exactly dstlen bytes from n characters; unused trailing bits are ignored, as in Go. */
bool bcrypt_b64_decode(uint8_t *dst, size_t dstlen, const char *src, size_t n) {
    uint32_t acc = 0;
    int bits = 0;
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        int v = b64_index(src[i]);
        if (v < 0) return false;
        acc = acc << 6 | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o < dstlen) dst[o] = (uint8_t)(acc >> bits);
            o++;
        }
    }
    return o == dstlen;
}

bool bcrypt_parse(const char *h, size_t n, struct bcrypt_setting *s) {
    /* "$2" [minor] "$" cost(2) "$" salt(22) hash(31) */
    size_t i = 3;
    if (n < 59 || h[0] != '$' || h[1] != '2') return false;
    s->minor = 0;
    if (h[2] != '$') {
        s->minor = h[2];
        if (h[3] != '$') return false;
        i = 4;
    }
    if (n != i + 2 + 1 + 22 + 31) return false;
    if (h[i] < '0' || h[i] > '9' || h[i + 1] < '0' || h[i + 1] > '9' || h[i + 2] != '$') return false;
    s->cost = (h[i] - '0') * 10 + (h[i + 1] - '0');
    if (s->cost < 4 || s->cost > 31) return false;
    i += 3;
    if (!bcrypt_b64_decode(s->salt, BCRYPT_SALT, h + i, 22)) return false;
    memcpy(s->hash, h + i + 22, 31);
    return true;
}

void bcrypt_hash(const char *pw, size_t pwlen, int cost, const uint8_t salt[BCRYPT_SALT], char out[BCRYPT_LEN + 1]) {
    uint8_t raw[BCRYPT_RAW];
    bcrypt_raw(pw, pwlen, salt, cost, raw);
    memcpy(out, "$2a$", 4);
    out[4] = (char)('0' + cost / 10);
    out[5] = (char)('0' + cost % 10);
    out[6] = '$';
    bcrypt_b64_encode(out + 7, salt, BCRYPT_SALT);
    bcrypt_b64_encode(out + 29, raw, BCRYPT_RAW);
    out[BCRYPT_LEN] = 0;
}

bool bcrypt_verify(const char *pw, size_t pwlen, const char *hash, size_t n) {
    struct bcrypt_setting s;
    uint8_t raw[BCRYPT_RAW];
    char enc[32];
    if (!bcrypt_parse(hash, n, &s) || pwlen > BCRYPT_MAX_PW) return false;
    bcrypt_raw(pw, pwlen, s.salt, s.cost, raw);
    bcrypt_b64_encode(enc, raw, BCRYPT_RAW);
    return ct_equal(enc, s.hash, 31);
}
