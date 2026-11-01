#include "crypto/jwt.h"

#include <limits.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "core/json.h"
#include "util.h"

#define JWT_HEADER "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
#define JWT_HEADER_LEN 36
#define SHA256_LEN 32

static const char B64URL[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static void b64url_encode(buf *out, const unsigned char *in, size_t len) {
    while (len >= 3) {
        unsigned v = (unsigned)in[0] << 16 | (unsigned)in[1] << 8 | in[2];
        buf_putc(out, B64URL[(v >> 18) & 0x3F]);
        buf_putc(out, B64URL[(v >> 12) & 0x3F]);
        buf_putc(out, B64URL[(v >> 6) & 0x3F]);
        buf_putc(out, B64URL[v & 0x3F]);
        in += 3;
        len -= 3;
    }
    if (len == 2) {
        unsigned v = (unsigned)in[0] << 16 | (unsigned)in[1] << 8;
        buf_putc(out, B64URL[(v >> 18) & 0x3F]);
        buf_putc(out, B64URL[(v >> 12) & 0x3F]);
        buf_putc(out, B64URL[(v >> 6) & 0x3F]);
    } else if (len == 1) {
        unsigned v = (unsigned)in[0] << 16;
        buf_putc(out, B64URL[(v >> 18) & 0x3F]);
        buf_putc(out, B64URL[(v >> 12) & 0x3F]);
    }
}

static int b64url_value(char ch) {
    static const signed char TABLE[128] = {
        ['A'] = 0, ['B'] = 1, ['C'] = 2, ['D'] = 3, ['E'] = 4, ['F'] = 5,
        ['G'] = 6, ['H'] = 7, ['I'] = 8, ['J'] = 9, ['K'] = 10, ['L'] = 11,
        ['M'] = 12, ['N'] = 13, ['O'] = 14, ['P'] = 15, ['Q'] = 16, ['R'] = 17,
        ['S'] = 18, ['T'] = 19, ['U'] = 20, ['V'] = 21, ['W'] = 22, ['X'] = 23,
        ['Y'] = 24, ['Z'] = 25, ['a'] = 26, ['b'] = 27, ['c'] = 28, ['d'] = 29,
        ['e'] = 30, ['f'] = 31, ['g'] = 32, ['h'] = 33, ['i'] = 34, ['j'] = 35,
        ['k'] = 36, ['l'] = 37, ['m'] = 38, ['n'] = 39, ['o'] = 40, ['p'] = 41,
        ['q'] = 42, ['r'] = 43, ['s'] = 44, ['t'] = 45, ['u'] = 46, ['v'] = 47,
        ['w'] = 48, ['x'] = 49, ['y'] = 50, ['z'] = 51, ['0'] = 52, ['1'] = 53,
        ['2'] = 54, ['3'] = 55, ['4'] = 56, ['5'] = 57, ['6'] = 58, ['7'] = 59,
        ['8'] = 60, ['9'] = 61, ['-'] = 62, ['_'] = 63,
    };
    unsigned char u = (unsigned char)ch;
    return u < 128 ? TABLE[u] : -1;
}

/* decoded length, -1 on alphabet/non-canonical error */
static int b64url_decode(unsigned char *out, size_t out_cap, const char *in,
                         size_t len) {
    if (len % 4 == 1) return -1;
    size_t needed = len / 4 * 3;
    if (len % 4 == 2) needed -= 1;
    if (len % 4 == 3) needed -= 2;
    if (needed > out_cap) return -1;

    unsigned v = 0;
    unsigned nbits = 0;
    size_t out_len = 0;
    for (size_t i = 0; i < len; i++) {
        int d = b64url_value(in[i]);
        if (d < 0) return -1;
        v = (v << 6) | (unsigned)d;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            out[out_len++] = (unsigned char)((v >> nbits) & 0xFF);
        }
    }
    return (int)out_len;
}

/* one-shot HMAC: no provider fetch / ctx allocation on every request (this
 * runs on every authenticated request), still plain OpenSSL and still one
 * real SHA-256 over the header+payload each time */
static bool hmac_sha256(const char *secret, const char *message,
                        size_t message_len, unsigned char out[SHA256_LEN]) {
    unsigned int out_len = 0;
    if (strlen(secret) > INT_MAX) return false;
    return HMAC(EVP_sha256(), secret, (int)strlen(secret),
                (const unsigned char *)message, message_len, out,
                &out_len) != NULL &&
           out_len == SHA256_LEN;
}

bool jwt_mint(buf *out, long long user_id, const char *secret,
              long long now_seconds) {
    char payload[128];
    int n = snprintf(payload, sizeof payload,
                     "{\"sub\":\"%lld\",\"iat\":%lld,\"exp\":%lld}",
                     user_id, now_seconds, now_seconds + JWT_TTL_SECONDS);
    if (n < 0 || (size_t)n >= sizeof payload) return false;

    size_t start = out->len;
    buf_append(out, JWT_HEADER, JWT_HEADER_LEN);
    buf_putc(out, '.');
    b64url_encode(out, (const unsigned char *)payload, (size_t)n);
    size_t signed_len = out->len - start;

    unsigned char signature[SHA256_LEN];
    if (!hmac_sha256(secret, out->data + start, signed_len, signature))
        return false;
    buf_putc(out, '.');
    b64url_encode(out, signature, SHA256_LEN);
    return true;
}

/* digits only: SPEC says sub is a decimal string of the user id */
static bool parse_subject(const char *s, long long *out) {
    if (!s || !s[0]) return false;
    long long value = 0;
    for (const char *p = s; *p; p++) {
        if (*p < '0' || *p > '9') return false;
        if (value > (LLONG_MAX - (*p - '0')) / 10) return false;
        value = value * 10 + (*p - '0');
    }
    *out = value;
    return true;
}

bool jwt_verify(long long *user_id, const char *token, const char *secret) {
    const char *dot1 = token ? strchr(token, '.') : NULL;
    const char *dot2 = dot1 ? strchr(dot1 + 1, '.') : NULL;
    if (!dot1 || !dot2 || strchr(dot2 + 1, '.')) return false;

    size_t header_len = (size_t)(dot1 - token);
    size_t payload_len = (size_t)(dot2 - dot1 - 1);
    size_t signature_len = strlen(dot2 + 1);
    if (header_len == 0 || payload_len == 0 || signature_len == 0) return false;

    unsigned char header[256];
    int header_decoded = b64url_decode(header, sizeof header - 1, token, header_len);
    if (header_decoded <= 0) return false;
    header[header_decoded] = '\0';

    const char *json_error = NULL;
    json_node *header_json = json_parse((const char *)header, (size_t)header_decoded,
                                        &json_error);
    if (!header_json) return false;
    const char *alg = json_str(json_get(header_json, "alg"));
    bool alg_ok = alg && strcmp(alg, "HS256") == 0;
    json_free(header_json);
    if (!alg_ok) return false;

    unsigned char expected[SHA256_LEN];
    if (!hmac_sha256(secret, token, (size_t)(dot2 - token), expected))
        return false;

    unsigned char signature[SHA256_LEN];
    int signature_decoded = b64url_decode(signature, sizeof signature, dot2 + 1,
                                          signature_len);
    if (signature_decoded != SHA256_LEN) return false;

    unsigned char diff = 0;
    for (size_t i = 0; i < SHA256_LEN; i++) diff |= signature[i] ^ expected[i];
    if (diff) return false;

    unsigned char payload[1024];
    int payload_decoded = b64url_decode(payload, sizeof payload - 1, dot1 + 1,
                                        payload_len);
    if (payload_decoded <= 0) return false;
    payload[payload_decoded] = '\0';

    json_node *claims = json_parse((const char *)payload, (size_t)payload_decoded,
                                   &json_error);
    if (!claims) return false;

    long long subject = 0;
    const json_node *sub = json_get(claims, "sub");
    const json_node *iat = json_get(claims, "iat");
    const json_node *exp = json_get(claims, "exp");
    bool ok = false;
    if (!parse_subject(json_str(sub), &subject)) goto done;
    if (!iat || iat->kind != JSON_NUM || !iat->is_int) goto done;
    if (!exp || exp->kind != JSON_NUM || !exp->is_int) goto done;

    long long lifetime;
    if (__builtin_sub_overflow(exp->num, iat->num, &lifetime)) goto done;
    if (lifetime != JWT_TTL_SECONDS) goto done;

    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) goto done;
    if ((long long)now.tv_sec >= exp->num) goto done;

    *user_id = subject;
    ok = true;
    done:
    json_free(claims);
    return ok;
}
