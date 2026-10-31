// MIT License — fork of c-iouring-tigokraft (#10); ideas from c-iouring-gilnett (#58), rust-tokio-Scooter1337 (#7), csharp-sockets-jh-d (#22).
// rw: Original MIT code (c) challenge contributors; modifications (c) frobinson. See README Credits.

// rw: Buffers, arenas, number formatting, SHA-256 / HMAC and base64.

#include "app.h"
#include <stdarg.h>

void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "conduit: fatal: ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(1);
}

void logf_(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "conduit: ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

// rw: ---------- buffers ----------


void buf_grow(buf_t *b, size_t need) {
    size_t cap = b->cap ? b->cap : 256;
    while (cap - b->len < need) cap *= 2;
    char *p = realloc(b->p, cap);
    if (!p) die("out of memory");
    b->p = p;
    b->cap = cap;
}

void buf_free(buf_t *b) {
    free(b->p);
    b->p = NULL;
    b->len = b->cap = 0;
}

size_t fmt_i64(char *out, int64_t v) {
    char tmp[24];
    size_t n = 0;
    uint64_t u = v < 0 ? -(uint64_t)v : (uint64_t)v;
    do { tmp[n++] = '0' + u % 10; u /= 10; } while (u);
    size_t o = 0;
    if (v < 0) out[o++] = '-';
    while (n) out[o++] = tmp[--n];
    return o;
}

void buf_i64(buf_t *b, int64_t v) {
    if (b->cap - b->len < 24) buf_grow(b, 24);
    b->len += fmt_i64(b->p + b->len, v);
}

static const char HEX[] = "0123456789abcdef";

// Word-at-a-time fast path for JSON escaping (own implementation, inspired by rust-mio 8B scan + SSE2 idea).
// rw: Scans 8 bytes via unaligned u64 load; bits trick detects bytes <0x20 or '"' (0x22) or '\\' (0x5C).

// rw: Falls back to byte loop for tail/specials. Identical output to byte loop.

void buf_json_str(buf_t *b, const char *s, size_t n) {
    if (b->cap - b->len < n + 2) buf_grow(b, n + 2);
    b->p[b->len++] = '"';
    size_t start = 0, i = 0;
    // rw: fast run: copy 8-byte chunks with no specials

    while (i + 8 <= n) {
        uint64_t word;
        __builtin_memcpy(&word, s + i, 8);
        // rw: high-bit per byte if <0x20, or == '"' or '\\'

        uint64_t lo = word & 0x7F7F7F7F7F7F7F7FULL;
        uint64_t has_ctrl = (lo + 0x6060606060606060ULL) & ~(word & 0x8080808080808080ULL) & 0x8080808080808080ULL;
        uint64_t is_q = 0, is_bs = 0;
        uint64_t tmp = word ^ 0x2222222222222222ULL;
        is_q = ((tmp - 0x0101010101010101ULL) & ~tmp & 0x8080808080808080ULL);
        tmp = word ^ 0x5C5C5C5C5C5C5C5CULL;
        is_bs = ((tmp - 0x0101010101010101ULL) & ~tmp & 0x8080808080808080ULL);
        if ((has_ctrl | is_q | is_bs) == 0) { i += 8; continue; }
        break;
    }
    for (; i < n; i++) {
        unsigned char c = s[i];
        if (__builtin_expect(c >= 0x20 && c != '"' && c != '\\', 1)) continue;
        buf_put(b, s + start, i - start);
        start = i + 1;
        switch (c) {
        case '"': buf_lit(b, "\\\""); break;
        case '\\': buf_lit(b, "\\\\"); break;
        case '\n': buf_lit(b, "\\n"); break;
        case '\r': buf_lit(b, "\\r"); break;
        case '\t': buf_lit(b, "\\t"); break;
        default: {
            char e[6] = {'\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15]};
            buf_put(b, e, 6);
        }
        }
        // rw: resume fast path after one special

        size_t j = i + 1;
        while (j + 8 <= n) {
            uint64_t word;
            __builtin_memcpy(&word, s + j, 8);
            uint64_t lo = word & 0x7F7F7F7F7F7F7F7FULL;
            uint64_t has_ctrl = (lo + 0x6060606060606060ULL) & ~(word & 0x8080808080808080ULL) & 0x8080808080808080ULL;
            uint64_t tmp = word ^ 0x2222222222222222ULL;
            uint64_t is_q = ((tmp - 0x0101010101010101ULL) & ~tmp & 0x8080808080808080ULL);
            tmp = word ^ 0x5C5C5C5C5C5C5C5CULL;
            uint64_t is_bs = ((tmp - 0x0101010101010101ULL) & ~tmp & 0x8080808080808080ULL);
            if ((has_ctrl | is_q | is_bs) == 0) { j += 8; continue; }
            break;
        }
        // rw: copy the fast run we just skipped (will be handled by outer loop's continue check)

        // rw: To keep logic simple, set i = j-1 so outer i++ lands on j

        if (j > i + 1) {
            // rw: flush pending run up to j via start adjustment: outer loop will scan byte-by-byte from i+1,

            // rw: but those bytes are known clean, so fast-forward

            i = j - 1;
            // rw: start already at correct place (after last special), no extra copy needed yet

        }
    }
    buf_put(b, s + start, n - start);
    buf_putc(b, '"');
}


void buf_json_nstr(buf_t *b, str_t s) {
    if (!s.p) buf_lit(b, "null");
    else buf_json_str(b, s.p, s.n);
}

// rw: ---------- arenas ----------


#define ARENA_CHUNK 4096

void *arena_alloc(arena_t *a, size_t n) {
    n = (n + 7) & ~(size_t)7;
    if (UNLIKELY((size_t)(a->end - a->cur) < n)) {
        size_t sz = n + sizeof(achunk_t) > ARENA_CHUNK ? n + sizeof(achunk_t) : ARENA_CHUNK;
        achunk_t *c = malloc(sz);
        if (!c) die("out of memory");
        c->next = a->chunks;
        c->size = sz;
        a->chunks = c;
        a->cur = (char *)(c + 1);
        a->end = (char *)c + sz;
    }
    void *p = a->cur;
    a->cur += n;
    return p;
}

char *arena_strdup(arena_t *a, const char *s, size_t n) {
    char *p = arena_alloc(a, n + 1);
    memcpy(p, s, n);
    p[n] = 0;
    return p;
}

void arena_free(arena_t *a) {
    achunk_t *c = a->chunks;
    while (c) {
        achunk_t *n = c->next;
        free(c);
        c = n;
    }
    a->chunks = NULL;
    a->cur = a->end = NULL;
}

// rw: Moves one cached chunk onto a fresh arena when it holds none. All other

// rw: allocations flow through arena_alloc unchanged, so pg.c/api.c benefit

// rw: without touching their call sites.

void arena_seed(struct ev_loop *w, arena_t *a) {
    if (!w || !a || a->chunks || !w->spare) return;
    achunk_t *c = w->spare;
    w->spare = c->next;
    w->spare_bytes -= c->size;
    c->next = NULL;
    a->chunks = c;
    a->cur = (char *)(c + 1);
    a->end = (char *)c + c->size;
}

// rw: Returns a request's chunks to the worker cache up to ARENA_SPARE_CAP;

// rw: anything past the cap is freed, bounding RSS. w->body capacity is

// rw: retained separately (http_reply_err resets len only, never frees).

void arena_recycle(struct ev_loop *w, arena_t *a) {
    if (!a) return;
    achunk_t *c = a->chunks;
    a->chunks = NULL;
    a->cur = a->end = NULL;
    if (!w) {
        while (c) {
            achunk_t *n = c->next;
            free(c);
            c = n;
        }
        return;
    }
    while (c) {
        achunk_t *n = c->next;
        if (w->spare_bytes + c->size <= ARENA_SPARE_CAP) {
            c->next = w->spare;
            w->spare = c;
            w->spare_bytes += c->size;
        } else {
            free(c);
        }
        c = n;
    }
}

bool parse_uint(const char *s, size_t n, int64_t *out) {
    if (n == 0 || n > 19) return false;
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] < '0' || s[i] > '9') return false;
        v = v * 10 + (s[i] - '0');
    }
    if (v > INT64_MAX) return false;
    *out = (int64_t)v;
    return true;
}

str_t arena_i64(arena_t *a, int64_t v) {
    char *p = arena_alloc(a, 24);
    return (str_t){p, fmt_i64(p, v)};
}

// rw: ---------- SHA-256 ----------


static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t h[8], const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = hh + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

void sha256_init(sha256_t *s) {
    static const uint32_t H0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, H0, sizeof H0);
    s->len = 0;
    s->blen = 0;
}

void sha256_update(sha256_t *s, const void *data, size_t n) {
    const uint8_t *p = data;
    s->len += n;
    if (s->blen) {
        size_t k = 64 - s->blen < n ? 64 - s->blen : n;
        memcpy(s->buf + s->blen, p, k);
        s->blen += k; p += k; n -= k;
        if (s->blen < 64) return;
        sha256_block(s->h, s->buf);
        s->blen = 0;
    }
    while (n >= 64) { sha256_block(s->h, p); p += 64; n -= 64; }
    memcpy(s->buf, p, n);
    s->blen = n;
}

void sha256_final(sha256_t *s, uint8_t out[32]) {
    uint64_t bits = s->len * 8;
    uint8_t pad = 0x80;
    sha256_update(s, &pad, 1);
    uint8_t z = 0;
    while (s->blen != 56) sha256_update(s, &z, 1);
    uint8_t L[8];
    for (int i = 0; i < 8; i++) L[i] = bits >> (56 - 8 * i);
    sha256_update(s, L, 8);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = s->h[i] >> 24; out[4 * i + 1] = s->h[i] >> 16;
        out[4 * i + 2] = s->h[i] >> 8; out[4 * i + 3] = s->h[i];
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

// rw: ---------- base64 ----------


static const char B64U[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
static const char B64S[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static size_t b64_enc_alpha(char *out, const uint8_t *in, size_t n, const char *al, bool pad) {
    size_t o = 0, i = 0;
    for (; i + 2 < n; i += 3) {
        uint32_t v = in[i] << 16 | in[i + 1] << 8 | in[i + 2];
        out[o++] = al[v >> 18]; out[o++] = al[(v >> 12) & 63];
        out[o++] = al[(v >> 6) & 63]; out[o++] = al[v & 63];
    }
    if (n - i == 1) {
        uint32_t v = in[i] << 16;
        out[o++] = al[v >> 18]; out[o++] = al[(v >> 12) & 63];
        if (pad) { out[o++] = '='; out[o++] = '='; }
    } else if (n - i == 2) {
        uint32_t v = in[i] << 16 | in[i + 1] << 8;
        out[o++] = al[v >> 18]; out[o++] = al[(v >> 12) & 63]; out[o++] = al[(v >> 6) & 63];
        if (pad) out[o++] = '=';
    }
    return o;
}

size_t b64url_enc(char *out, const uint8_t *in, size_t n) { return b64_enc_alpha(out, in, n, B64U, false); }
size_t b64_enc(char *out, const uint8_t *in, size_t n) { return b64_enc_alpha(out, in, n, B64S, true); }

static int b64v(char c, bool url) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == (url ? '-' : '+')) return 62;
    if (c == (url ? '_' : '/')) return 63;
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
        int v = b64v(in[i], url);
        if (v < 0) return -1;
        acc = acc << 6 | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[o++] = acc >> bits;
        }
    }
    return (long)o;
}

long b64url_dec(uint8_t *out, const char *in, size_t n) { return b64_dec_alpha(out, in, n, true); }
long b64_dec(uint8_t *out, const char *in, size_t n) { return b64_dec_alpha(out, in, n, false); }
