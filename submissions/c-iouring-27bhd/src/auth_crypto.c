#include "auth_crypto.h"
#include "json_simd.h"

#if defined(__x86_64__) && (defined(__SHA__) || defined(__AVX2__))
#include <immintrin.h>
#endif

hmac_midstate_t g_jwt_hmac;

#define ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z)  (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x) (ROR32(x, 2) ^ ROR32(x, 13) ^ ROR32(x, 22))
#define EP1(x) (ROR32(x, 6) ^ ROR32(x, 11) ^ ROR32(x, 25))
#define SIG0(x) (ROR32(x, 7) ^ ROR32(x, 18) ^ ((x) >> 3))
#define SIG1(x) (ROR32(x, 17) ^ ROR32(x, 19) ^ ((x) >> 10))

static const uint32_t K256[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

static void sha256_init(sha256_ctx_t *ctx) {
    ctx->state[0] = 0x6a09e667;
    ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372;
    ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f;
    ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab;
    ctx->state[7] = 0x5be0cd19;
    ctx->count = 0;
}

static void sha256_transform(uint32_t state[8], const uint8_t *data) {
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
    uint32_t w[64];

    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)data[i * 4] << 24) |
               ((uint32_t)data[i * 4 + 1] << 16) |
               ((uint32_t)data[i * 4 + 2] << 8) |
               ((uint32_t)data[i * 4 + 3]);
    }
    for (int i = 16; i < 64; i++) {
        w[i] = SIG1(w[i - 2]) + w[i - 7] + SIG0(w[i - 15]) + w[i - 16];
    }
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + EP1(e) + CH(e, f, g) + K256[i] + w[i];
        uint32_t t2 = EP0(a) + MAJ(a, b, c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

static void sha256_update(sha256_ctx_t *ctx, const uint8_t *data, size_t len) {
    size_t index = (size_t)(ctx->count & 0x3f);
    ctx->count += len;
    size_t part_len = 64 - index;
    size_t i = 0;

    if (len >= part_len) {
        memcpy(&ctx->buffer[index], data, part_len);
        sha256_transform(ctx->state, ctx->buffer);
        for (i = part_len; i + 63 < len; i += 64) {
            sha256_transform(ctx->state, &data[i]);
        }
        index = 0;
    }
    memcpy(&ctx->buffer[index], &data[i], len - i);
}

static void sha256_final(sha256_ctx_t *ctx, uint8_t digest[32]) {
    uint8_t final_count[8];
    uint64_t bits = ctx->count * 8;
    for (int i = 0; i < 8; i++) {
        final_count[7 - i] = (uint8_t)(bits >> (i * 8));
    }
    size_t index = (size_t)(ctx->count & 0x3f);
    size_t pad_len = (index < 56) ? (56 - index) : (120 - index);
    static const uint8_t padding[64] = { 0x80 };
    sha256_update(ctx, padding, pad_len);
    sha256_update(ctx, final_count, 8);
    for (int i = 0; i < 8; i++) {
        digest[i * 4]     = (uint8_t)(ctx->state[i] >> 24);
        digest[i * 4 + 1] = (uint8_t)(ctx->state[i] >> 16);
        digest[i * 4 + 2] = (uint8_t)(ctx->state[i] >> 8);
        digest[i * 4 + 3] = (uint8_t)(ctx->state[i]);
    }
}

static void hmac_init(hmac_midstate_t *ms, const uint8_t *key, size_t key_len) {
    uint8_t k_pad[64];
    uint8_t k0[64];
    memset(k0, 0, 64);
    if (key_len > 64) {
        sha256_ctx_t c;
        sha256_init(&c);
        sha256_update(&c, key, key_len);
        sha256_final(&c, k0);
    } else {
        memcpy(k0, key, key_len);
    }

    for (int i = 0; i < 64; i++) k_pad[i] = k0[i] ^ 0x36;
    sha256_ctx_t in_ctx;
    sha256_init(&in_ctx);
    sha256_transform(in_ctx.state, k_pad);
    memcpy(ms->inner_state, in_ctx.state, 32);

    for (int i = 0; i < 64; i++) k_pad[i] = k0[i] ^ 0x5c;
    sha256_ctx_t out_ctx;
    sha256_init(&out_ctx);
    sha256_transform(out_ctx.state, k_pad);
    memcpy(ms->outer_state, out_ctx.state, 32);
}

static void hmac_compute(const hmac_midstate_t *ms, const uint8_t *msg, size_t msg_len, uint8_t out[32]) {
    sha256_ctx_t in_ctx;
    memcpy(in_ctx.state, ms->inner_state, 32);
    in_ctx.count = 64;

    sha256_update(&in_ctx, msg, msg_len);
    uint8_t inner_hash[32];
    sha256_final(&in_ctx, inner_hash);

    sha256_ctx_t out_ctx;
    memcpy(out_ctx.state, ms->outer_state, 32);
    out_ctx.count = 64;

    sha256_update(&out_ctx, inner_hash, 32);
    sha256_final(&out_ctx, out);
}

static const char b64url_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
static int8_t g_b64url_rev[256];

int b64url_encode(const uint8_t *in, int in_len, char *out) {
    int w = 0;
    for (int i = 0; i < in_len; i += 3) {
        uint32_t b0 = in[i];
        uint32_t b1 = (i + 1 < in_len) ? in[i + 1] : 0;
        uint32_t b2 = (i + 2 < in_len) ? in[i + 2] : 0;
        uint32_t triple = (b0 << 16) | (b1 << 8) | b2;

        out[w++] = b64url_table[(triple >> 18) & 0x3f];
        out[w++] = b64url_table[(triple >> 12) & 0x3f];
        if (i + 1 < in_len) out[w++] = b64url_table[(triple >> 6) & 0x3f];
        if (i + 2 < in_len) out[w++] = b64url_table[triple & 0x3f];
    }
    out[w] = '\0';
    return w;
}

int b64url_decode(const char *in, int in_len, uint8_t *out) {
    int w = 0;
    uint32_t buf = 0;
    int bits = 0;
    for (int i = 0; i < in_len; i++) {
        unsigned char c = (unsigned char)in[i];
        if (c == '=') break;
        int8_t val = g_b64url_rev[c];
        if (val < 0) return -1;
        buf = (buf << 6) | (uint32_t)val;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[w++] = (uint8_t)(buf >> bits);
        }
    }
    return w;
}

static const char JWT_HEADER_B64[] = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
#define JWT_HEADER_B64_LEN 36

void auth_init(const char *secret) {
    hmac_init(&g_jwt_hmac, (const uint8_t *)secret, strlen(secret));
    memset(g_b64url_rev, -1, sizeof(g_b64url_rev));
    for (int i = 0; i < 64; i++) {
        g_b64url_rev[(unsigned char)b64url_table[i]] = (int8_t)i;
    }
}

int jwt_issue(int64_t user_id, char *out_token) {
    memcpy(out_token, JWT_HEADER_B64, JWT_HEADER_B64_LEN);
    out_token[JWT_HEADER_B64_LEN] = '.';
    int pos = JWT_HEADER_B64_LEN + 1;

    char payload[256];
    int64_t now = (int64_t)time(NULL);
    int64_t exp = now + 30 * 24 * 3600;

    char sub_s[24], iat_s[24], exp_s[24];
    int sub_l = u64_to_str((uint64_t)user_id, sub_s);
    int iat_l = u64_to_str((uint64_t)now, iat_s);
    int exp_l = u64_to_str((uint64_t)exp, exp_s);

    int plen = 0;
    memcpy(payload + plen, "{\"sub\":\"", 8); plen += 8;
    memcpy(payload + plen, sub_s, sub_l); plen += sub_l;
    memcpy(payload + plen, "\",\"iat\":", 8); plen += 8;
    memcpy(payload + plen, iat_s, iat_l); plen += iat_l;
    memcpy(payload + plen, ",\"exp\":", 7); plen += 7;
    memcpy(payload + plen, exp_s, exp_l); plen += exp_l;
    payload[plen++] = '}';

    pos += b64url_encode((const uint8_t *)payload, plen, out_token + pos);

    out_token[pos++] = '.';
    uint8_t sig[32];
    hmac_compute(&g_jwt_hmac, (const uint8_t *)out_token, pos - 1, sig);
    pos += b64url_encode(sig, 32, out_token + pos);
    out_token[pos] = '\0';
    return pos;
}

int64_t jwt_verify(const char *token) {
    if (!token) return 0;
    const char *dot1 = strchr(token, '.');
    if (!dot1) return 0;
    const char *dot2 = strchr(dot1 + 1, '.');
    if (!dot2) return 0;

    int head_len = (int)(dot1 - token);
    int payload_len = (int)(dot2 - dot1 - 1);
    const char *sig_str = dot2 + 1;
    int sig_str_len = (int)strlen(sig_str);

    uint8_t sig_calc[32];
    hmac_compute(&g_jwt_hmac, (const uint8_t *)token, (size_t)(dot2 - token), sig_calc);
    char sig_calc_b64[64];
    int calc_len = b64url_encode(sig_calc, 32, sig_calc_b64);
    if (calc_len != sig_str_len || memcmp(sig_calc_b64, sig_str, calc_len) != 0) {
        return 0;
    }

    if (!(head_len == 36 && memcmp(token, JWT_HEADER_B64, 36) == 0)) {
        uint8_t head_json[256];
        int hj_len = b64url_decode(token, head_len, head_json);
        if (hj_len <= 0 || hj_len >= 255) return 0;
        head_json[hj_len] = '\0';
        if (!strstr((char *)head_json, "\"HS256\"") || strstr((char *)head_json, "\"none\"")) {
            return 0;
        }
    }

    uint8_t payload_json[512];
    int pj_len = b64url_decode(dot1 + 1, payload_len, payload_json);
    if (pj_len <= 0 || pj_len >= 511) return 0;
    payload_json[pj_len] = '\0';

    char *exp_ptr = strstr((char *)payload_json, "\"exp\":");
    if (!exp_ptr) exp_ptr = strstr((char *)payload_json, "\"exp\" :");
    if (!exp_ptr) return 0;
    exp_ptr += 6;
    while (*exp_ptr == ' ' || *exp_ptr == ':') exp_ptr++;
    int64_t exp_val = strtoll(exp_ptr, NULL, 10);
    int64_t now = (int64_t)time(NULL);
    if (exp_val <= now) {
        return 0;
    }

    char *sub_ptr = strstr((char *)payload_json, "\"sub\":");
    if (!sub_ptr) sub_ptr = strstr((char *)payload_json, "\"sub\" :");
    if (!sub_ptr) return 0;
    sub_ptr += 6;
    while (*sub_ptr == ' ' || *sub_ptr == ':') sub_ptr++;
    if (*sub_ptr != '"') return 0;
    sub_ptr++;
    if (*sub_ptr < '0' || *sub_ptr > '9') return 0;
    char *end_sub;
    int64_t user_id = strtoll(sub_ptr, &end_sub, 10);
    if (user_id <= 0 || *end_sub != '"') return 0;

    return user_id;
}

bool hash_password(const char *pw, char *out_hash, size_t out_hash_size) {
    if (!pw || strlen(pw) > 72) return false;
    char setting[64];
    if (!crypt_gensalt_rn("$2b$", 10, NULL, 0, setting, sizeof(setting))) {
        return false;
    }
    struct crypt_data data;
    memset(&data, 0, sizeof(data));
    char *h = crypt_rn(pw, setting, &data, sizeof(data));
    if (!h) return false;
    if (strlen(h) >= out_hash_size) return false;
    strcpy(out_hash, h);
    return true;
}

bool verify_password(const char *pw, const char *stored_hash) {
    if (!pw || !stored_hash || strlen(pw) > 72) return false;
    struct crypt_data data;
    memset(&data, 0, sizeof(data));
    char *v = crypt_rn(pw, stored_hash, &data, sizeof(data));
    if (!v) return false;
    return (strcmp(stored_hash, v) == 0);
}
