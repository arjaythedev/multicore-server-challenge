#include "jwt.h"

#include "base64.h"
#include "buf.h"
#include "hmac.h"
#include "json_in.h"

/* Segments longer than this are not tokens we issue or accept. */
#define SEG_MAX 1024

static struct hmac_key key;
static char header_b64[64];
static size_t header_b64_len;

void jwt_init(const char *secret, size_t n) {
    static const char header[] = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    hmac_key_init(&key, secret, n);
    header_b64_len = b64url_encode(header_b64, header, sizeof header - 1);
}

size_t jwt_sign(char out[JWT_MAX], int64_t uid, int64_t now) {
    char payload[96], *p = payload;
    uint8_t mac[SHA256_LEN];

    memcpy(p, "{\"sub\":\"", 8), p += 8;
    p += fmt_u64(p, (uint64_t)uid);
    memcpy(p, "\",\"iat\":", 8), p += 8;
    p += fmt_u64(p, (uint64_t)now);
    memcpy(p, ",\"exp\":", 7), p += 7;
    p += fmt_u64(p, (uint64_t)(now + JWT_TTL));
    *p++ = '}';

    char *o = out;
    memcpy(o, header_b64, header_b64_len), o += header_b64_len;
    *o++ = '.';
    o += b64url_encode(o, payload, (size_t)(p - payload));
    hmac_sha256_k(&key, out, (size_t)(o - out), mac);
    *o++ = '.';
    o += b64url_encode(o, mac, sizeof mac);
    return (size_t)(o - out);
}

/* Decodes a base64url segment and parses it as a JSON object. */
static const struct jval *segment_object(struct arena *a, const char *s, size_t n) {
    if (n > SEG_MAX) return NULL;
    char *raw = arena_alloc(a, n);
    ptrdiff_t len = b64url_decode(raw, s, n);
    if (len < 0) return NULL;
    const struct jval *v = json_parse(a, raw, (size_t)len);
    return v && v->type == J_OBJ ? v : NULL;
}

/* An optional claim that must have one of the given types when present and not null. */
static bool claim_type_ok(const struct jval *v, enum jtype want) {
    return !v || v->type == J_NULL || v->type == want;
}

static bool audience_ok(const struct jval *v) {
    if (!v || v->type == J_NULL || v->type == J_STR) return true;
    if (v->type != J_ARR) return false;
    for (const struct jval *c = v->child; c; c = c->next)
        if (c->type != J_STR) return false;
    return true;
}

bool jwt_verify(struct arena *a, const char *tok, size_t n, double now, int64_t *uid) {
    const char *d1 = memchr(tok, '.', n);
    if (!d1) return false;
    const char *d2 = memchr(d1 + 1, '.', n - (size_t)(d1 + 1 - tok));
    if (!d2 || memchr(d2 + 1, '.', n - (size_t)(d2 + 1 - tok))) return false;

    /* Signature first: it is the cheapest complete rejection of a forged token. */
    uint8_t sig[48], mac[SHA256_LEN];
    size_t siglen = n - (size_t)(d2 + 1 - tok);
    if (siglen > 64 || b64url_decode(sig, d2 + 1, siglen) != SHA256_LEN) return false;
    hmac_sha256_k(&key, tok, (size_t)(d2 - tok), mac);
    if (!ct_equal(sig, mac, SHA256_LEN)) return false;

    const struct jval *hdr = segment_object(a, tok, (size_t)(d1 - tok));
    if (!hdr) return false;
    const struct jval *alg = json_getl(hdr, "alg");
    if (!alg || alg->type != J_STR || alg->len != 5 || memcmp(alg->s, "HS256", 5) != 0) return false;

    const struct jval *claims = segment_object(a, d1 + 1, (size_t)(d2 - d1 - 1));
    if (!claims) return false;
    const struct jval *exp = json_getl(claims, "exp"), *nbf = json_getl(claims, "nbf");
    const struct jval *sub = json_getl(claims, "sub");
    if (!exp || exp->type != J_NUM || !(now < json_num(exp))) return false;
    if (!claim_type_ok(nbf, J_NUM) || (nbf && nbf->type == J_NUM && now < json_num(nbf))) return false;
    if (!claim_type_ok(json_getl(claims, "iat"), J_NUM) || !claim_type_ok(json_getl(claims, "iss"), J_STR) ||
        !claim_type_ok(json_getl(claims, "jti"), J_STR) || !audience_ok(json_getl(claims, "aud")))
        return false;

    /* sub: ASCII digits only, fitting an int64, and not 0. */
    if (!sub || sub->type != J_STR || sub->len == 0 || sub->len > 19) return false;
    uint64_t id = 0;
    for (uint32_t i = 0; i < sub->len; i++) {
        char c = sub->s[i];
        if (c < '0' || c > '9') return false;
        id = id * 10 + (uint64_t)(c - '0');
    }
    if (id == 0 || id > INT64_MAX) return false;
    *uid = (int64_t)id;
    return true;
}
