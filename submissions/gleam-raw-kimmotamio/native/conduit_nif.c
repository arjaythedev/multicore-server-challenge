/*
 * Small NIFs on the request path: JSON string escaping, RFC 3339 timestamp formatting, the decoding of a
 * Postgres DataRow and of a binary text[] into sub-binaries, HS256 JWT verification and the HTTP request head. Each is a few hundred nanoseconds at most for what
 * Conduit produces, well under the NIF budget, and replaces a recursive pass of BIF calls and intermediate terms.
 */
#include <stdint.h>
#include <string.h>
#include "erl_nif.h"

/* Extra bytes a character adds when escaped: 0 for the plain ones. */
static unsigned char escape_extra[256];
static ERL_NIF_TERM atom_none, atom_some, atom_fast, atom_rejected, atom_general, atom_request, atom_more, atom_bad, atom_true, atom_false;
static void b64url_init(void);

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    int c;
    (void)priv; (void)info;
    atom_none = enif_make_atom(env, "none");
    atom_some = enif_make_atom(env, "some");
    atom_fast = enif_make_atom(env, "fast");
    atom_rejected = enif_make_atom(env, "rejected");
    atom_general = enif_make_atom(env, "general");
    atom_request = enif_make_atom(env, "request");
    atom_more = enif_make_atom(env, "more");
    atom_bad = enif_make_atom(env, "bad");
    atom_true = enif_make_atom(env, "true");
    atom_false = enif_make_atom(env, "false");
    b64url_init();
    for (c = 0; c < 256; c++) escape_extra[c] = 0;
    for (c = 0; c < 32; c++) escape_extra[c] = 5; /* \u00XX */
    escape_extra['\n'] = escape_extra['\r'] = escape_extra['\t'] = escape_extra['\b'] = escape_extra['\f'] = 1;
    escape_extra['"'] = escape_extra['\\'] = 1;
    return 0;
}

/*
 * json_string(Bin) -> iodata. When nothing needs escaping the result is [$", Bin, $"] around the original binary
 * (no copy); otherwise one new binary with the quotes and the escapes. Escapes exactly what RFC 8259 requires:
 * the quote, the backslash and the control characters below 0x20; everything else, including non-ASCII, is
 * passed through as UTF-8.
 */
static ERL_NIF_TERM nif_json_string(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary in;
    size_t i, extra = 0;
    const unsigned char *p;
    unsigned char *o;
    ERL_NIF_TERM out;
    static const char hex[] = "0123456789abcdef";
    if (argc != 1 || !enif_inspect_binary(env, argv[0], &in)) return enif_make_badarg(env);
    p = in.data;
    for (i = 0; i < in.size; i++) extra += escape_extra[p[i]];
    if (extra == 0) {
        ERL_NIF_TERM quote = enif_make_int(env, '"');
        return enif_make_list3(env, quote, argv[0], quote);
    }
    o = enif_make_new_binary(env, in.size + extra + 2, &out);
    *o++ = '"';
    for (i = 0; i < in.size; i++) {
        unsigned char c = p[i];
        if (escape_extra[c] == 0) {
            *o++ = c;
            continue;
        }
        *o++ = '\\';
        switch (c) {
        case '"': *o++ = '"'; break;
        case '\\': *o++ = '\\'; break;
        case '\n': *o++ = 'n'; break;
        case '\r': *o++ = 'r'; break;
        case '\t': *o++ = 't'; break;
        case '\b': *o++ = 'b'; break;
        case '\f': *o++ = 'f'; break;
        default:
            *o++ = 'u'; *o++ = '0'; *o++ = '0';
            *o++ = (unsigned char)hex[c >> 4];
            *o++ = (unsigned char)hex[c & 15];
            break;
        }
    }
    *o = '"';
    return out;
}

static int64_t floor_div(int64_t a, int64_t b) {
    int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
    return q;
}

static void put2(unsigned char *o, int64_t v) {
    o[0] = (unsigned char)('0' + (v / 10) % 10);
    o[1] = (unsigned char)('0' + v % 10);
}

/*
 * Formats microseconds since 2000-01-01T00:00:00Z (Postgres' binary timestamptz) as
 * "YYYY-MM-DDTHH:MM:SS.mmmZ", truncated to milliseconds. Same arithmetic as util.rfc3339 in Gleam, which the
 * tests compare this against.
 */
static void format_rfc3339(int64_t micros, unsigned char *o) {
    int64_t secs = floor_div(micros, 1000000);
    int64_t ms = (micros - secs * 1000000) / 1000;
    int64_t unix_s = secs + 946684800;
    int64_t days = floor_div(unix_s, 86400);
    int64_t sod = unix_s - days * 86400;
    int64_t z = days + 719468;
    int64_t era = floor_div(z, 146097);
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    int64_t d = doy - (153 * mp + 2) / 5 + 1;
    int64_t m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) y++;
    y %= 10000;
    if (y < 0) y += 10000;
    o[0] = (unsigned char)('0' + y / 1000);
    o[1] = (unsigned char)('0' + (y / 100) % 10);
    o[2] = (unsigned char)('0' + (y / 10) % 10);
    o[3] = (unsigned char)('0' + y % 10);
    o[4] = '-';
    put2(o + 5, m);
    o[7] = '-';
    put2(o + 8, d);
    o[10] = 'T';
    put2(o + 11, sod / 3600);
    o[13] = ':';
    put2(o + 14, (sod % 3600) / 60);
    o[16] = ':';
    put2(o + 17, sod % 60);
    o[19] = '.';
    o[20] = (unsigned char)('0' + ms / 100);
    o[21] = (unsigned char)('0' + (ms / 10) % 10);
    o[22] = (unsigned char)('0' + ms % 10);
    o[23] = 'Z';
}

static ERL_NIF_TERM nif_rfc3339(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifSInt64 micros;
    ERL_NIF_TERM out;
    unsigned char *o;
    if (argc != 1 || !enif_get_int64(env, argv[0], &micros)) return enif_make_badarg(env);
    o = enif_make_new_binary(env, 24, &out);
    format_rfc3339((int64_t)micros, o);
    return out;
}

/* The same timestamp as a JSON string literal, quotes included. */
static ERL_NIF_TERM nif_json_rfc3339(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifSInt64 micros;
    ERL_NIF_TERM out;
    unsigned char *o;
    if (argc != 1 || !enif_get_int64(env, argv[0], &micros)) return enif_make_badarg(env);
    o = enif_make_new_binary(env, 26, &out);
    o[0] = '"';
    format_rfc3339((int64_t)micros, o + 1);
    o[25] = '"';
    return out;
}

static uint32_t be32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

#define MAX_FIELDS 256

/*
 * decode_row(Payload) -> [Option(BitArray)]: a DataRow body (int16 column count, then int32 length + bytes per
 * column, -1 for NULL) as a list of `none` | {some, SubBinary}. The sub-binaries share the socket buffer, as
 * the Gleam decoder's did. A truncated row yields the columns that were complete.
 */
static ERL_NIF_TERM nif_decode_row(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary in;
    ERL_NIF_TERM cols[MAX_FIELDS];
    unsigned n, i;
    size_t pos = 2;
    if (argc != 1 || !enif_inspect_binary(env, argv[0], &in)) return enif_make_badarg(env);
    if (in.size < 2) return enif_make_list(env, 0);
    n = ((unsigned)in.data[0] << 8) | in.data[1];
    if (n > MAX_FIELDS) return enif_make_badarg(env);
    for (i = 0; i < n; i++) {
        uint32_t len;
        if (pos + 4 > in.size) break;
        len = be32(in.data + pos);
        pos += 4;
        if (len == 0xFFFFFFFFu) {
            cols[i] = atom_none;
        } else {
            if (pos + len > in.size) break;
            cols[i] = enif_make_tuple2(env, atom_some, enif_make_sub_binary(env, argv[0], pos, len));
            pos += len;
        }
    }
    return enif_make_list_from_array(env, cols, i);
}

/*
 * decode_text_array(Bin) -> [BitArray]: a one-dimensional array in Postgres binary format (int32 ndim, flags,
 * element oid, then per dimension int32 count and lower bound, then int32 length + bytes per element, -1 for
 * NULL). NULL elements and anything malformed past the header yield the elements that were complete; a NULL
 * element becomes an empty binary, as in the Gleam decoder.
 */
static ERL_NIF_TERM nif_decode_text_array(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary in;
    ERL_NIF_TERM *elems;
    ERL_NIF_TERM out;
    uint32_t ndim, n, i;
    size_t pos = 12;
    if (argc != 1 || !enif_inspect_binary(env, argv[0], &in)) return enif_make_badarg(env);
    if (in.size < 12) return enif_make_list(env, 0);
    ndim = be32(in.data);
    if (ndim == 0) return enif_make_list(env, 0);
    if (ndim != 1 || in.size < 20) return enif_make_list(env, 0);
    n = be32(in.data + 12);
    pos = 20;
    if (n > 100000) return enif_make_badarg(env);
    elems = enif_alloc(sizeof(ERL_NIF_TERM) * (n == 0 ? 1 : n));
    if (!elems) return enif_make_badarg(env);
    for (i = 0; i < n; i++) {
        uint32_t len;
        if (pos + 4 > in.size) break;
        len = be32(in.data + pos);
        pos += 4;
        if (len == 0xFFFFFFFFu) {
            elems[i] = enif_make_sub_binary(env, argv[0], 0, 0);
        } else {
            if (pos + len > in.size) break;
            elems[i] = enif_make_sub_binary(env, argv[0], pos, len);
            pos += len;
        }
    }
    out = enif_make_list_from_array(env, elems, i);
    enif_free(elems);
    return out;
}


/* ---------------------------------------------------------------- HS256 JWT verification
 *
 * jwt_verify(Token, Secret, Now) -> {fast, Sub} | rejected | general. The fast path covers the one shape every
 * issuer here produces (the standard header, a flat {"sub":"<id>","iat":<n>,"exp":<n>} payload, a 43-character
 * unpadded signature): HMAC-SHA256 over the signed part, the expected signature encoded and compared in constant
 * time, then the payload decoded and read. Any other shape is `general`, left to the Erlang/Gleam path, which
 * accepts the same tokens more slowly; `rejected` is a bad signature, a payload that does not decode, or an
 * expired token. SHA-256 is the FIPS 180-4 routine written out below (no OpenSSL round trip per request).
 */
typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t buflen; } sha256_ctx;

static const uint32_t sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

#define ROTR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t h[8], const uint8_t p[64]) {
    uint32_t w[64], a, b, c, d, e, f, g, hh, t1, t2;
    int i;
    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) | ((uint32_t)p[4 * i + 2] << 8) | p[4 * i + 3];
    for (i = 16; i < 64; i++) {
        uint32_t s0 = ROTR32(w[i - 15], 7) ^ ROTR32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROTR32(w[i - 2], 17) ^ ROTR32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
    for (i = 0; i < 64; i++) {
        uint32_t S1 = ROTR32(e, 6) ^ ROTR32(e, 11) ^ ROTR32(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t S0 = ROTR32(a, 2) ^ ROTR32(a, 13) ^ ROTR32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        t1 = hh + S1 + ch + sha256_k[i] + w[i];
        t2 = S0 + maj;
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void sha256_init(sha256_ctx *c) {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(c->h, iv, sizeof iv);
    c->len = 0;
    c->buflen = 0;
}

static void sha256_update(sha256_ctx *c, const uint8_t *d, size_t n) {
    c->len += n;
    if (c->buflen) {
        size_t take = 64 - c->buflen;
        if (take > n) take = n;
        memcpy(c->buf + c->buflen, d, take);
        c->buflen += take;
        d += take;
        n -= take;
        if (c->buflen < 64) return;
        sha256_block(c->h, c->buf);
        c->buflen = 0;
    }
    while (n >= 64) {
        sha256_block(c->h, d);
        d += 64;
        n -= 64;
    }
    if (n) {
        memcpy(c->buf, d, n);
        c->buflen = n;
    }
}

static void sha256_final(sha256_ctx *c, uint8_t out[32]) {
    uint64_t bits = c->len * 8;
    int i;
    c->buf[c->buflen++] = 0x80;
    if (c->buflen > 56) {
        memset(c->buf + c->buflen, 0, 64 - c->buflen);
        sha256_block(c->h, c->buf);
        c->buflen = 0;
    }
    memset(c->buf + c->buflen, 0, 56 - c->buflen);
    for (i = 0; i < 8; i++) c->buf[56 + i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_block(c->h, c->buf);
    for (i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(c->h[i] >> 24);
        out[4 * i + 1] = (uint8_t)(c->h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(c->h[i] >> 8);
        out[4 * i + 3] = (uint8_t)c->h[i];
    }
}

static void hmac_sha256(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen, uint8_t out[32]) {
    uint8_t k[64], pad[64], inner[32];
    sha256_ctx c;
    size_t i;
    memset(k, 0, sizeof k);
    if (klen > 64) {
        sha256_init(&c);
        sha256_update(&c, key, klen);
        sha256_final(&c, k);
    } else {
        memcpy(k, key, klen);
    }
    for (i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
    sha256_init(&c);
    sha256_update(&c, pad, 64);
    sha256_update(&c, msg, mlen);
    sha256_final(&c, inner);
    for (i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5c;
    sha256_init(&c);
    sha256_update(&c, pad, 64);
    sha256_update(&c, inner, 32);
    sha256_final(&c, out);
}

static const char b64url[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
static signed char b64url_rev[256];

static void b64url_init(void) {
    int i;
    for (i = 0; i < 256; i++) b64url_rev[i] = -1;
    for (i = 0; i < 64; i++) b64url_rev[(unsigned char)b64url[i]] = (signed char)i;
}

/* 32 bytes -> 43 characters, no padding. */
static void b64url_encode32(const uint8_t *in, char *out) {
    int i, o = 0;
    for (i = 0; i + 3 <= 30; i += 3) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i + 1] << 8) | in[i + 2];
        out[o++] = b64url[(v >> 18) & 63];
        out[o++] = b64url[(v >> 12) & 63];
        out[o++] = b64url[(v >> 6) & 63];
        out[o++] = b64url[v & 63];
    }
    {   /* 2 bytes left: 3 characters */
        uint32_t v = ((uint32_t)in[30] << 10) | ((uint32_t)in[31] << 2);
        out[o++] = b64url[(v >> 12) & 63];
        out[o++] = b64url[(v >> 6) & 63];
        out[o++] = b64url[v & 63];
    }
}

/* Unpadded base64url. Returns the decoded length or -1 when a character is invalid or the length is impossible. */
static int b64url_decode(const uint8_t *in, size_t n, uint8_t *out, size_t cap) {
    size_t i, o = 0;
    uint32_t acc = 0;
    int bits = 0;
    if (n % 4 == 1) return -1;
    if ((n / 4) * 3 + 2 > cap) return -1;
    for (i = 0; i < n; i++) {
        int v = b64url_rev[in[i]];
        if (v < 0) return -1;
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[o++] = (uint8_t)(acc >> bits);
        }
    }
    /* Trailing bits must be zero, as the Erlang decoder requires. */
    if (bits && (acc & ((1u << bits) - 1))) return -1;
    return (int)o;
}

/* Up to 18 ASCII digits -> value; returns the count consumed (0 when none). */
static int take_digits(const uint8_t *p, const uint8_t *end, int64_t *val) {
    int n = 0;
    int64_t v = 0;
    while (p + n < end && p[n] >= '0' && p[n] <= '9' && n < 18) {
        v = v * 10 + (p[n] - '0');
        n++;
    }
    *val = v;
    return n;
}

static int take_lit(const uint8_t **p, const uint8_t *end, const char *lit) {
    size_t n = strlen(lit);
    if ((size_t)(end - *p) < n || memcmp(*p, lit, n) != 0) return 0;
    *p += n;
    return 1;
}

#define JWT_HEADER "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
#define JWT_HEADER_LEN 36

static ERL_NIF_TERM nif_jwt_verify(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary token, secret;
    ErlNifSInt64 now;
    const uint8_t *payload, *sig, *p, *end;
    size_t payload_len, signed_len;
    uint8_t mac[32], claims[1024];
    char expected[43];
    unsigned diff = 0;
    int n, i;
    int64_t sub, iat, exp;
    if (argc != 3 || !enif_inspect_binary(env, argv[0], &token) || !enif_inspect_binary(env, argv[1], &secret)
        || !enif_get_int64(env, argv[2], &now))
        return enif_make_badarg(env);
    /* header "." payload "." 43 signature characters, payload at least one character */
    if (token.size < JWT_HEADER_LEN + 1 + 1 + 1 + 43) return atom_general;
    if (memcmp(token.data, JWT_HEADER ".", JWT_HEADER_LEN + 1) != 0) return atom_general;
    signed_len = token.size - 44;
    if (token.data[signed_len] != '.') return atom_general;
    sig = token.data + signed_len + 1;
    payload = token.data + JWT_HEADER_LEN + 1;
    payload_len = signed_len - JWT_HEADER_LEN - 1;
    if (memchr(payload, '.', payload_len) != NULL) return atom_general;
    for (i = 0; i < 43; i++) if (b64url_rev[sig[i]] < 0) return atom_general;
    hmac_sha256(secret.data, secret.size, token.data, signed_len, mac);
    b64url_encode32(mac, expected);
    for (i = 0; i < 43; i++) diff |= (unsigned)(expected[i] ^ sig[i]);
    if (diff != 0) return atom_rejected;
    n = b64url_decode(payload, payload_len, claims, sizeof claims);
    if (n < 0) return payload_len > 1360 ? atom_general : atom_rejected;
    p = claims;
    end = claims + n;
    if (!take_lit(&p, end, "{\"sub\":\"")) return atom_general;
    i = take_digits(p, end, &sub);
    if (i == 0) return atom_general;
    p += i;
    if (!take_lit(&p, end, "\",\"iat\":")) return atom_general;
    i = take_digits(p, end, &iat);
    if (i == 0) return atom_general;
    p += i;
    if (!take_lit(&p, end, ",\"exp\":")) return atom_general;
    i = take_digits(p, end, &exp);
    if (i == 0) return atom_general;
    p += i;
    if (!take_lit(&p, end, "}") || p != end) return atom_general;
    if (sub <= 0) return atom_general;
    if (exp <= now) return atom_rejected;
    return enif_make_tuple2(env, atom_fast, enif_make_int64(env, sub));
}

/* hmac_sha256(Key, Data) -> binary: the routine above, exposed so the tests can hold it to crypto:mac/4. */
static ERL_NIF_TERM nif_hmac_sha256(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary key, data, out;
    if (argc != 2 || !enif_inspect_binary(env, argv[0], &key) || !enif_inspect_binary(env, argv[1], &data))
        return enif_make_badarg(env);
    if (!enif_alloc_binary(32, &out)) return enif_make_badarg(env);
    hmac_sha256(key.data, key.size, data.data, data.size, out.data);
    return enif_make_binary(env, &out);
}


/* ---------------------------------------------------------------- HTTP request head
 *
 * parse_request(Buf) -> {request, Method, Segments, Query, Authorization, Body, Rest, Close} | more | bad
 *
 * One pass over the request line, the headers and the body length, with every piece a sub-binary of Buf: what
 * erlang:decode_packet(http_bin/httph_bin) plus two binary:split calls did in eight BIF calls. The rules are
 * those of the Erlang version it replaces (kept as conduit_ffi:parse_request_ref/1 for the tests), and as
 * lenient as decode_packet: lines end in LF with an optional CR, the request line is `METHOD SP+ /target SP+
 * HTTP/d.d SP*` (the version may be missing, as in HTTP/0.9), the target must be UTF-8 with no control
 * characters, a header name may be empty, header values lose leading but not
 * trailing blanks, `Content-Length` is an optional `+` and digits up to 1 MB (the last one wins),
 * a `Transfer-Encoding` header is refused, `Connection: close` (any case) closes after the response, the head
 * must fit in 16 KB, and the body must be complete or the answer is `more`. Continuation lines (obs-fold) are
 * refused. Segments are the path split on every `/` with empty pieces kept, as
 * binary:split(Path, <<"/">>, [global]) gives them.
 */
#define HEAD_LIMIT 16384
#define BODY_LIMIT 1048576
#define MAX_SEGMENTS 64

static int utf8_valid(const uint8_t *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        uint8_t c = p[i];
        if (c < 0x80) { i++; continue; }
        if (c < 0xC2) return 0;
        if (c < 0xE0) {
            if (i + 1 >= n || (p[i + 1] & 0xC0) != 0x80) return 0;
            i += 2;
        } else if (c < 0xF0) {
            uint32_t cp;
            if (i + 2 >= n || (p[i + 1] & 0xC0) != 0x80 || (p[i + 2] & 0xC0) != 0x80) return 0;
            cp = ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(p[i + 1] & 0x3F) << 6) | (p[i + 2] & 0x3F);
            if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
            i += 3;
        } else if (c < 0xF5) {
            uint32_t cp;
            if (i + 3 >= n || (p[i + 1] & 0xC0) != 0x80 || (p[i + 2] & 0xC0) != 0x80 || (p[i + 3] & 0xC0) != 0x80) return 0;
            cp = ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(p[i + 1] & 0x3F) << 12) | ((uint32_t)(p[i + 2] & 0x3F) << 6) | (p[i + 3] & 0x3F);
            if (cp < 0x10000 || cp > 0x10FFFF) return 0;
            i += 4;
        } else {
            return 0;
        }
    }
    return 1;
}

static int is_tchar(uint8_t c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (c < 0x80 && c > 0x20 && strchr("!#$%&'*+-.^_`|~", c) != NULL);
}

static int ci_equal(const uint8_t *a, size_t n, const char *lit) {
    size_t i;
    if (strlen(lit) != n) return 0;
    for (i = 0; i < n; i++) {
        uint8_t c = a[i];
        if (c >= 'A' && c <= 'Z') c += 32;
        if (c != (uint8_t)lit[i]) return 0;
    }
    return 1;
}

/* The next line: [*line, *line_end) without its CR/LF; *next is where the following line starts. Returns 0 when no
 * line feed is in the first `limit` bytes. */
static int next_line(const uint8_t *p, const uint8_t *end, size_t limit, const uint8_t **line, const uint8_t **line_end, const uint8_t **next) {
    size_t n = (size_t)(end - p);
    const uint8_t *lf;
    if (n > limit) n = limit;
    lf = memchr(p, '\n', n);
    if (!lf) return 0;
    *line = p;
    *line_end = (lf > p && lf[-1] == '\r') ? lf - 1 : lf;
    *next = lf + 1;
    return 1;
}

static ERL_NIF_TERM nif_parse_request(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary in;
    const uint8_t *base, *end, *line, *line_end, *next, *p, *target, *q;
    size_t target_len, path_len, i, method_len, path_off, query_off, query_len, auth_off = 0, auth_len = 0, body_off, seg_start, remaining;
    int64_t content_length = 0;
    int close = 0, chunked = 0, nseg = 0;
    ERL_NIF_TERM segs[MAX_SEGMENTS], segments, query, auth, body, rest, method;
    if (argc != 1 || !enif_inspect_binary(env, argv[0], &in)) return enif_make_badarg(env);
    base = in.data;
    end = in.data + in.size;
    /* request line */
    if (!next_line(base, end, HEAD_LIMIT, &line, &line_end, &next)) return in.size >= HEAD_LIMIT ? atom_bad : atom_more;
    p = line;
    while (p < line_end && is_tchar(*p)) p++;
    method_len = (size_t)(p - line);
    if (method_len == 0 || method_len > 20 || p == line_end || *p != ' ') return atom_bad;
    while (p < line_end && *p == ' ') p++;
    target = p;
    while (p < line_end && *p != ' ') p++;
    target_len = (size_t)(p - target);
    if (target_len == 0 || target[0] != '/') return atom_bad;
    while (p < line_end && *p == ' ') p++;
    if (p != line_end) { /* a version; its absence (HTTP/0.9 style) is accepted as decode_packet accepts it */
        if (line_end - p < 8 || memcmp(p, "HTTP/", 5) != 0 || p[5] < '0' || p[5] > '9' || p[6] != '.' || p[7] < '0' || p[7] > '9') return atom_bad;
        p += 8;
        while (p < line_end && *p == ' ') p++;
        if (p != line_end) return atom_bad;
    }
    for (i = 0; i < target_len; i++) if (target[i] <= 0x20 || target[i] == 0x7F) return atom_bad;
    if (!utf8_valid(target, target_len)) return atom_bad;
    q = memchr(target, '?', target_len);
    path_off = (size_t)(target - base);
    if (q) {
        path_len = (size_t)(q - target);
        query_off = path_off + path_len + 1;
        query_len = target_len - path_len - 1;
    } else {
        path_len = target_len;
        query_off = path_off + path_len;
        query_len = 0;
    }
    /* headers, up to the empty line */
    p = next;
    for (;;) {
        const uint8_t *colon, *v;
        size_t nlen;
        remaining = HEAD_LIMIT - (size_t)(p - base);
        if ((size_t)(p - base) >= HEAD_LIMIT) return atom_bad;
        if (!next_line(p, end, remaining, &line, &line_end, &next)) return in.size - (size_t)(p - base) >= remaining ? atom_bad : atom_more;
        if (line_end == line) break;
        if (line[0] == ' ' || line[0] == '\t') return atom_bad; /* obs-fold */
        colon = memchr(line, ':', (size_t)(line_end - line));
        if (!colon) return atom_bad;
        nlen = (size_t)(colon - line);
        for (i = 0; i < nlen; i++) if (!is_tchar(line[i])) return atom_bad;
        v = colon + 1;
        while (v < line_end && (*v == ' ' || *v == '\t')) v++;
        if (ci_equal(line, nlen, "authorization")) {
            auth_off = (size_t)(v - base);
            auth_len = (size_t)(line_end - v);
        } else if (ci_equal(line, nlen, "content-length")) {
            int64_t n = 0;
            const uint8_t *d = v;
            if (d < line_end && *d == '+') d++;
            if (d == line_end) return atom_bad;
            for (; d < line_end; d++) {
                if (*d < '0' || *d > '9') return atom_bad;
                n = n * 10 + (*d - '0');
                if (n > BODY_LIMIT) return atom_bad;
            }
            content_length = n;
        } else if (ci_equal(line, nlen, "connection")) {
            close = ci_equal(v, (size_t)(line_end - v), "close");
        } else if (ci_equal(line, nlen, "transfer-encoding")) {
            chunked = 1;
        }
        p = next;
    }
    if (chunked) return atom_bad;
    body_off = (size_t)(next - base);
    if (in.size - body_off < (size_t)content_length) return atom_more;
    /* path segments: split on every '/' */
    seg_start = path_off;
    for (i = path_off; i <= path_off + path_len; i++) {
        if (i == path_off + path_len || base[i] == '/') {
            if (nseg == MAX_SEGMENTS) return atom_bad;
            segs[nseg++] = enif_make_sub_binary(env, argv[0], seg_start, i - seg_start);
            seg_start = i + 1;
        }
    }
    segments = enif_make_list_from_array(env, segs, nseg);
    method = enif_make_sub_binary(env, argv[0], 0, method_len);
    query = enif_make_sub_binary(env, argv[0], query_off, query_len);
    auth = enif_make_sub_binary(env, argv[0], auth_off, auth_len);
    body = enif_make_sub_binary(env, argv[0], body_off, (size_t)content_length);
    rest = enif_make_sub_binary(env, argv[0], body_off + (size_t)content_length, in.size - body_off - (size_t)content_length);
    return enif_make_tuple8(env, atom_request, method, segments, query, auth, body, rest, close ? atom_true : atom_false);
}


/*
 * json_string_array([Bin]) -> binary: `["a","b"]` with every element escaped as json_string escapes it, built
 * in one binary. The tags list is 200 names: as a nested iolist it was 600 small terms for the writer to walk.
 */
static ERL_NIF_TERM nif_json_string_array(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM list, head, tail, out;
    ErlNifBinary bin;
    size_t total = 2, i;
    unsigned n = 0;
    unsigned char *o;
    static const char hex[] = "0123456789abcdef";
    if (argc != 1 || !enif_is_list(env, argv[0])) return enif_make_badarg(env);
    for (list = argv[0]; enif_get_list_cell(env, list, &head, &tail); list = tail) {
        if (!enif_inspect_binary(env, head, &bin)) return enif_make_badarg(env);
        total += bin.size + 3; /* quotes and a comma */
        for (i = 0; i < bin.size; i++) total += escape_extra[bin.data[i]];
        n++;
    }
    if (!enif_is_empty_list(env, list)) return enif_make_badarg(env);
    o = enif_make_new_binary(env, total - (n ? 1 : 0), &out);
    *o++ = '[';
    for (list = argv[0]; enif_get_list_cell(env, list, &head, &tail); list = tail) {
        enif_inspect_binary(env, head, &bin);
        if (list != argv[0]) *o++ = ',';
        *o++ = '"';
        for (i = 0; i < bin.size; i++) {
            unsigned char c = bin.data[i];
            if (!escape_extra[c]) { *o++ = c; continue; }
            *o++ = '\\';
            switch (c) {
            case '"': *o++ = '"'; break;
            case '\\': *o++ = '\\'; break;
            case '\n': *o++ = 'n'; break;
            case '\r': *o++ = 'r'; break;
            case '\t': *o++ = 't'; break;
            case '\b': *o++ = 'b'; break;
            case '\f': *o++ = 'f'; break;
            default:
                *o++ = 'u'; *o++ = '0'; *o++ = '0'; *o++ = hex[c >> 4]; *o++ = hex[c & 15];
            }
        }
        *o++ = '"';
    }
    *o++ = ']';
    return out;
}

static ErlNifFunc funcs[] = {
    {"json_string", 1, nif_json_string, 0},
    {"rfc3339", 1, nif_rfc3339, 0},
    {"json_rfc3339", 1, nif_json_rfc3339, 0},
    {"decode_row", 1, nif_decode_row, 0},
    {"decode_text_array", 1, nif_decode_text_array, 0},
    {"jwt_verify", 3, nif_jwt_verify, 0},
    {"hmac_sha256", 2, nif_hmac_sha256, 0},
    {"parse_request", 1, nif_parse_request, 0},
    {"json_string_array", 1, nif_json_string_array, 0},
};

ERL_NIF_INIT(conduit_nif, funcs, load, NULL, NULL, NULL)
