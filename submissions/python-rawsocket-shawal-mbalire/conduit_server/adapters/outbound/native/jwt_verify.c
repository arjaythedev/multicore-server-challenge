/* HS256 JWT verification for the tokens this server issues, as a CPython extension (a ctypes call would cost about
 * as much as the work).
 *
 *   init(key: bytes, header: bytes)   HMAC key; header is the exact first segment of the tokens we issue
 *   verify(token: str) -> int | None  user id; ValueError if rejected; None when the token isn't in our own form
 *                                     (crypto_adapter then runs the Python check, which decides it)
 *
 * The fast path accepts exactly what the Python check accepts on tokens of our form: header == ours, payload
 * {"sub":"<digits>","iat":<digits>,"exp":<digits>}, signature compared after strict base64url decoding (like
 * binascii.a2b_base64, the unused low bits of the last character are ignored). Anything else returns None.
 * SHA-256 uses the SHA-NI instructions when the CPU has them, else portable C. HMAC's ipad/opad blocks are hashed
 * once in init, so a verify costs 3 compressions for a ~150-byte token. */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <cpuid.h>
#include <immintrin.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static const uint32_t H0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void compress_c(uint32_t st[8], const uint8_t *blk) {
    uint32_t w[64], a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], h = st[7];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)blk[4 * i] << 24 | (uint32_t)blk[4 * i + 1] << 16 | (uint32_t)blk[4 * i + 2] << 8 | blk[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    st[0] += a; st[1] += b; st[2] += c; st[3] += d; st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

/* One block with the SHA extensions (the usual sha256rnds2/msg1/msg2 schedule). */
__attribute__((target("sha,sse4.1"))) static void compress_ni(uint32_t st[8], const uint8_t *blk) {
    const __m128i MASK = _mm_set_epi64x(0x0c0d0e0f08090a0bULL, 0x0405060700010203ULL);
    __m128i tmp = _mm_loadu_si128((const __m128i *)&st[0]);
    __m128i s1 = _mm_loadu_si128((const __m128i *)&st[4]);
    tmp = _mm_shuffle_epi32(tmp, 0xB1);            /* CDAB */
    s1 = _mm_shuffle_epi32(s1, 0x1B);              /* EFGH */
    __m128i s0 = _mm_alignr_epi8(tmp, s1, 8);      /* ABEF */
    s1 = _mm_blend_epi16(s1, tmp, 0xF0);           /* CDGH */
    __m128i abef = s0, cdgh = s1, msg, m[4];
    for (int i = 0; i < 4; i++) m[i] = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *)(blk + 16 * i)), MASK);
    for (int r = 0; r < 16; r++) {
        __m128i *cur = &m[r & 3];
        if (r >= 4) {
            /* m[r&3] = msg2(msg1(m[r&3], m[(r+1)&3]) + alignr(m[(r+3)&3], m[(r+2)&3], 4), m[(r+3)&3]) */
            __m128i t = _mm_sha256msg1_epu32(*cur, m[(r + 1) & 3]);
            t = _mm_add_epi32(t, _mm_alignr_epi8(m[(r + 3) & 3], m[(r + 2) & 3], 4));
            *cur = _mm_sha256msg2_epu32(t, m[(r + 3) & 3]);
        }
        msg = _mm_add_epi32(*cur, _mm_loadu_si128((const __m128i *)&K[4 * r]));
        s1 = _mm_sha256rnds2_epu32(s1, s0, msg);
        msg = _mm_shuffle_epi32(msg, 0x0E);
        s0 = _mm_sha256rnds2_epu32(s0, s1, msg);
    }
    s0 = _mm_add_epi32(s0, abef);
    s1 = _mm_add_epi32(s1, cdgh);
    tmp = _mm_shuffle_epi32(s0, 0x1B);             /* FEBA */
    s1 = _mm_shuffle_epi32(s1, 0xB1);              /* DCHG */
    s0 = _mm_blend_epi16(tmp, s1, 0xF0);           /* DCBA */
    s1 = _mm_alignr_epi8(s1, tmp, 8);              /* ABEF */
    _mm_storeu_si128((__m128i *)&st[0], s0);
    _mm_storeu_si128((__m128i *)&st[4], s1);
}

static void (*compress)(uint32_t st[8], const uint8_t *blk) = compress_c;

/* Hashes msg after `prefix_len` bytes already absorbed into st (a multiple of 64); writes the 32-byte digest. */
static void sha256_finish(uint32_t st[8], uint64_t prefix_len, const uint8_t *msg, size_t len, uint8_t out[32]) {
    uint64_t bits = (prefix_len + len) * 8;
    for (; len >= 64; msg += 64, len -= 64) compress(st, msg);
    uint8_t blk[128] = {0};
    memcpy(blk, msg, len);
    blk[len] = 0x80;
    size_t n = len + 9 <= 64 ? 64 : 128;
    for (int i = 0; i < 8; i++) blk[n - 1 - i] = (uint8_t)(bits >> (8 * i));
    compress(st, blk);
    if (n == 128) compress(st, blk + 64);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = st[i] >> 24; out[4 * i + 1] = st[i] >> 16; out[4 * i + 2] = st[i] >> 8; out[4 * i + 3] = st[i];
    }
}

static uint32_t inner0[8], outer0[8]; /* states after the ipad / opad key blocks */
static char header[128];
static Py_ssize_t header_len = -1;
static int8_t B64[256];               /* base64url value, -1 outside the alphabet */

/* Strict base64url without padding into out; length in *outlen. -1 if a character is outside the alphabet or the
 * length can't be base64 (len % 4 == 1). Like a2b_base64, the leftover low bits of the last character are dropped. */
static int b64url_decode(const char *s, Py_ssize_t len, uint8_t *out, Py_ssize_t *outlen) {
    if ((len & 3) == 1) return -1;
    Py_ssize_t o = 0;
    uint32_t acc = 0;
    int nbits = 0;
    for (Py_ssize_t i = 0; i < len; i++) {
        int v = B64[(uint8_t)s[i]];
        if (v < 0) return -1;
        acc = acc << 6 | (uint32_t)v;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            out[o++] = (uint8_t)(acc >> nbits);
        }
    }
    *outlen = o;
    return 0;
}

/* `"name":<digits>` at *p (the quote included), quoted if `quoted`; up to 15 digits, no leading zero unless "0".
 * Advances *p. -1 if it doesn't match. */
static int64_t field(const char **p, const char *end, const char *name, int quoted) {
    size_t n = strlen(name);
    const char *s = *p;
    if (end - s < (Py_ssize_t)n + 3 || s[0] != '"' || memcmp(s + 1, name, n) || s[n + 1] != '"' || s[n + 2] != ':')
        return -1;
    s += n + 3;
    if (quoted && (s == end || *s++ != '"')) return -1;
    const char *d = s;
    int64_t v = 0;
    while (s < end && *s >= '0' && *s <= '9' && s - d < 16) v = v * 10 + (*s++ - '0');
    if (s == d || s - d > 15 || (*d == '0' && s - d > 1)) return -1;
    if (quoted && (s == end || *s++ != '"')) return -1;
    *p = s;
    return v;
}

static PyObject *rejected(const char *why) {
    PyErr_SetString(PyExc_ValueError, why);
    return NULL;
}

/* States after the ipad and opad blocks of `key`. */
static void key_states(const char *key, Py_ssize_t key_len, uint32_t inner[8], uint32_t outer[8]) {
    uint8_t k[64] = {0}, blk[64];
    if (key_len > 64) { /* HMAC hashes long keys first */
        uint32_t st[8];
        memcpy(st, H0, sizeof st);
        sha256_finish(st, 0, (const uint8_t *)key, (size_t)key_len, k);
    } else {
        memcpy(k, key, (size_t)key_len);
    }
    for (int i = 0; i < 64; i++) blk[i] = k[i] ^ 0x36;
    memcpy(inner, H0, sizeof H0);
    compress(inner, blk);
    for (int i = 0; i < 64; i++) blk[i] = k[i] ^ 0x5c;
    memcpy(outer, H0, sizeof H0);
    compress(outer, blk);
}

static void hmac_from(const uint32_t inner[8], const uint32_t outer[8], const uint8_t *msg, size_t len,
                      uint8_t mac[32]) {
    uint32_t st[8];
    memcpy(st, inner, sizeof st);
    sha256_finish(st, 64, msg, len, mac);
    memcpy(st, outer, sizeof st);
    sha256_finish(st, 64, mac, 32, mac);
}

static PyObject *init(PyObject *self, PyObject *args) {
    const char *key, *hdr;
    Py_ssize_t key_len, hdr_len;
    if (!PyArg_ParseTuple(args, "y#y#", &key, &key_len, &hdr, &hdr_len)) return NULL;
    if (hdr_len >= (Py_ssize_t)sizeof header) return rejected("header too long");
    key_states(key, key_len, inner0, outer0);
    memcpy(header, hdr, (size_t)hdr_len);
    header_len = hdr_len;
    Py_RETURN_NONE;
}

/* hmac_sha256(key, msg) -> bytes: for the self-test against hashlib. */
static PyObject *hmac_sha256(PyObject *self, PyObject *args) {
    const char *key, *msg;
    Py_ssize_t key_len, msg_len;
    if (!PyArg_ParseTuple(args, "y#y#", &key, &key_len, &msg, &msg_len)) return NULL;
    uint32_t inner[8], outer[8];
    uint8_t mac[32];
    key_states(key, key_len, inner, outer);
    hmac_from(inner, outer, (const uint8_t *)msg, (size_t)msg_len, mac);
    return PyBytes_FromStringAndSize((const char *)mac, 32);
}

static PyObject *verify(PyObject *self, PyObject *arg) {
    Py_ssize_t len;
    if (header_len < 0) return rejected("jwt_verify.init was not called");
    if (!PyUnicode_Check(arg) || !PyUnicode_IS_ASCII(arg)) Py_RETURN_NONE;
    const char *tok = PyUnicode_AsUTF8AndSize(arg, &len);
    if (!tok) return NULL;
    const char *dot1 = memchr(tok, '.', len);
    if (!dot1) Py_RETURN_NONE;
    const char *dot2 = memchr(dot1 + 1, '.', tok + len - dot1 - 1);
    if (!dot2 || memchr(dot2 + 1, '.', tok + len - dot2 - 1)) Py_RETURN_NONE;
    if (dot1 - tok != header_len || memcmp(tok, header, header_len)) Py_RETURN_NONE;
    const char *sig = dot2 + 1;
    Py_ssize_t sig_len = tok + len - sig, n;
    uint8_t want[33], mac[32];
    if (sig_len != 43 || b64url_decode(sig, sig_len, want, &n)) Py_RETURN_NONE;

    hmac_from(inner0, outer0, (const uint8_t *)tok, (size_t)(dot2 - tok), mac);
    uint8_t diff = 0;
    for (int i = 0; i < 32; i++) diff |= mac[i] ^ want[i];
    if (diff) return rejected("bad signature");

    uint8_t payload[256];
    Py_ssize_t plen = dot2 - dot1 - 1;
    if (plen > 336 || b64url_decode(dot1 + 1, plen, payload, &n)) Py_RETURN_NONE;
    const char *p = (const char *)payload, *end = p + n;
    if (p == end || *p++ != '{') Py_RETURN_NONE;
    int64_t sub = field(&p, end, "sub", 1);
    if (sub < 0 || p == end || *p++ != ',') Py_RETURN_NONE;
    int64_t iat = field(&p, end, "iat", 0);
    if (iat < 0 || p == end || *p++ != ',') Py_RETURN_NONE;
    int64_t exp = field(&p, end, "exp", 0);
    if (exp < 0 || p == end || *p++ != '}' || p != end) Py_RETURN_NONE;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts); /* time.time()'s clock */
    double now = (double)ts.tv_sec + ts.tv_nsec * 1e-9;
    if ((double)exp <= now) return rejected("expired");
    if ((double)iat > now) return rejected("issued in the future");
    return PyLong_FromLongLong(sub);
}

static PyObject *backend(PyObject *self, PyObject *unused) {
    return PyUnicode_FromString(compress == compress_ni ? "sha-ni" : "c");
}

static PyMethodDef methods[] = {
    {"init", init, METH_VARARGS, "init(key: bytes, header: bytes)"},
    {"verify", verify, METH_O, "verify(token: str) -> int | None; ValueError if rejected"},
    {"hmac_sha256", hmac_sha256, METH_VARARGS, "hmac_sha256(key, msg) -> bytes (self-test)"},
    {"backend", backend, METH_NOARGS, "'sha-ni' or 'c'"},
    {NULL, NULL, 0, NULL}};

static int exec_module(PyObject *m) {
    unsigned a, b, c, d;
    /* SHA, SSE4.1, SSSE3; JWT_PORTABLE_SHA=1 forces the C path (for testing it) */
    if (!getenv("JWT_PORTABLE_SHA") && __get_cpuid_count(7, 0, &a, &b, &c, &d) && (b & (1u << 29)) &&
        __get_cpuid(1, &a, &b, &c, &d) && (c & (1u << 19)) && (c & (1u << 9)))
        compress = compress_ni;
    memset(B64, -1, sizeof B64);
    const char *alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    for (int i = 0; i < 64; i++) B64[(uint8_t)alpha[i]] = (int8_t)i;
    return 0;
}

static PyModuleDef_Slot slots[] = {
    {Py_mod_exec, exec_module},
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},
    {0, NULL}};

static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "_jwt_verify", NULL, 0, methods, NULL, NULL, NULL, NULL};

PyMODINIT_FUNC PyInit__jwt_verify(void) {
    module.m_slots = slots;
    return PyModuleDef_Init(&module);
}
