// SHA-256 (SHA-NI when the CPU has it), HMAC, PBKDF2, base64, HS256 tokens.
#include <stdio.h>
#include <time.h>

#include "common.h"
#if defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>
#endif

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be,
    0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa,
    0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
    0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
    0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void block_c(uint32_t st[8], const uint8_t *p, size_t nblk) {
  while (nblk--) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[i * 4] << 24 | p[i * 4 + 1] << 16 | p[i * 4 + 2] << 8 | p[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
      uint32_t a = w[i - 15], b = w[i - 2];
      w[i] = w[i - 16] + (ROR(a, 7) ^ ROR(a, 18) ^ (a >> 3)) + w[i - 7] + (ROR(b, 17) ^ ROR(b, 19) ^ (b >> 10));
    }
    uint32_t a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], h = st[7];
    for (int i = 0; i < 64; i++) {
      uint32_t t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
      uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    st[0] += a; st[1] += b; st[2] += c; st[3] += d; st[4] += e; st[5] += f; st[6] += g; st[7] += h;
    p += 64;
  }
}

#if defined(__x86_64__)
__attribute__((target("sha,sse4.1,ssse3"))) static void block_ni(uint32_t st[8], const uint8_t *p, size_t nblk) {
  const __m128i MASK = _mm_set_epi64x(0x0c0d0e0f08090a0bULL, 0x0405060700010203ULL);
  __m128i t = _mm_shuffle_epi32(_mm_loadu_si128((void *)st), 0xB1);
  __m128i s1 = _mm_shuffle_epi32(_mm_loadu_si128((void *)(st + 4)), 0x1B);
  __m128i s0 = _mm_alignr_epi8(t, s1, 8);
  s1 = _mm_blend_epi16(s1, t, 0xF0);
  while (nblk--) {
    __m128i a0 = s0, b0 = s1, m[4], msg, tmp;
    for (int i = 0; i < 4; i++) m[i] = _mm_shuffle_epi8(_mm_loadu_si128((const void *)(p + 16 * i)), MASK);
    for (int i = 0; i < 16; i++) {
      __m128i cur = m[i & 3];
      msg = _mm_add_epi32(cur, _mm_loadu_si128((const void *)&K[i * 4]));
      s1 = _mm_sha256rnds2_epu32(s1, s0, msg);
      s0 = _mm_sha256rnds2_epu32(s0, s1, _mm_shuffle_epi32(msg, 0x0E));
      if (i < 12) {
        tmp = _mm_sha256msg1_epu32(m[i & 3], m[(i + 1) & 3]);
        tmp = _mm_add_epi32(tmp, _mm_alignr_epi8(m[(i + 3) & 3], m[(i + 2) & 3], 4));
        m[i & 3] = _mm_sha256msg2_epu32(tmp, m[(i + 3) & 3]);
      }
    }
    s0 = _mm_add_epi32(s0, a0);
    s1 = _mm_add_epi32(s1, b0);
    p += 64;
  }
  t = _mm_shuffle_epi32(s0, 0x1B);
  s1 = _mm_shuffle_epi32(s1, 0xB1);
  _mm_storeu_si128((void *)st, _mm_blend_epi16(t, s1, 0xF0));
  _mm_storeu_si128((void *)(st + 4), _mm_alignr_epi8(s1, t, 8));
}
#endif

static void (*block)(uint32_t[8], const uint8_t *, size_t) = block_c;

static const uint32_t H0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

void sha256_init_cpu(void) {
#if defined(__x86_64__)
  unsigned a, b, c, d;
  if (__get_cpuid_count(7, 0, &a, &b, &c, &d) && (b & (1u << 29))) block = block_ni;
#endif
}

// Finishes a hash whose first `done` bytes (a multiple of 64) are already in st.
static void finish(uint32_t st[8], const uint8_t *d, size_t n, size_t done, uint8_t out[32]) {
  size_t whole = n & ~(size_t)63;
  if (whole) block(st, d, whole / 64);
  uint8_t t[128] = {0};
  size_t r = n - whole;
  memcpy(t, d + whole, r);
  t[r] = 0x80;
  size_t tl = r < 56 ? 64 : 128;
  uint64_t bits = (done + n) * 8;
  for (int i = 0; i < 8; i++) t[tl - 1 - i] = (uint8_t)(bits >> (8 * i));
  block(st, t, tl / 64);
  for (int i = 0; i < 8; i++) {
    out[i * 4] = st[i] >> 24;
    out[i * 4 + 1] = st[i] >> 16;
    out[i * 4 + 2] = st[i] >> 8;
    out[i * 4 + 3] = st[i];
  }
}

void sha256(const void *d, size_t n, uint8_t out[32]) {
  uint32_t st[8];
  memcpy(st, H0, 32);
  finish(st, d, n, 0, out);
}

typedef struct {
  uint32_t in[8], out[8];
} hmac_mid;
static void hmac_setup(hmac_mid *m, const void *k, size_t kl) {
  uint8_t key[64] = {0}, pad[64];
  if (kl > 64) sha256(k, kl, key);
  else memcpy(key, k, kl);
  for (int i = 0; i < 64; i++) pad[i] = key[i] ^ 0x36;
  memcpy(m->in, H0, 32);
  block(m->in, pad, 1);
  for (int i = 0; i < 64; i++) pad[i] = key[i] ^ 0x5c;
  memcpy(m->out, H0, 32);
  block(m->out, pad, 1);
}
static void hmac_run(const hmac_mid *m, const void *d, size_t n, uint8_t out[32]) {
  uint32_t st[8];
  uint8_t t[32];
  memcpy(st, m->in, 32);
  finish(st, d, n, 64, t);
  memcpy(st, m->out, 32);
  finish(st, t, 32, 64, out);
}
void hmac_sha256(const void *k, size_t kl, const void *d, size_t n, uint8_t out[32]) {
  hmac_mid m;
  hmac_setup(&m, k, kl);
  hmac_run(&m, d, n, out);
}

void pbkdf2_sha256(const void *pw, size_t pl, const void *salt, size_t sl, int iters, uint8_t out[32]) {
  hmac_mid m;
  hmac_setup(&m, pw, pl);
  uint8_t t[128], u[32];
  if (sl > sizeof t - 4) abort();
  memcpy(t, salt, sl);
  t[sl] = t[sl + 1] = t[sl + 2] = 0;
  t[sl + 3] = 1;
  hmac_run(&m, t, sl + 4, u);
  memcpy(out, u, 32);
  for (int i = 1; i < iters; i++) {
    hmac_run(&m, u, 32, u);
    for (int j = 0; j < 32; j++) out[j] ^= u[j];
  }
}

static const char B64S[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char B64U[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static size_t enc(const char *T, const uint8_t *in, size_t n, char *o, bool pad) {
  char *s = o;
  size_t i = 0;
  for (; i + 3 <= n; i += 3) {
    uint32_t v = in[i] << 16 | in[i + 1] << 8 | in[i + 2];
    *o++ = T[v >> 18]; *o++ = T[(v >> 12) & 63]; *o++ = T[(v >> 6) & 63]; *o++ = T[v & 63];
  }
  if (n - i == 1) {
    uint32_t v = in[i] << 16;
    *o++ = T[v >> 18]; *o++ = T[(v >> 12) & 63];
    if (pad) { *o++ = '='; *o++ = '='; }
  } else if (n - i == 2) {
    uint32_t v = in[i] << 16 | in[i + 1] << 8;
    *o++ = T[v >> 18]; *o++ = T[(v >> 12) & 63]; *o++ = T[(v >> 6) & 63];
    if (pad) *o++ = '=';
  }
  return o - s;
}
size_t b64_std_encode(const uint8_t *in, size_t n, char *out) { return enc(B64S, in, n, out, true); }

static int dec_val(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+' || c == '-') return 62;
  if (c == '/' || c == '_') return 63;
  return -1;
}
// Decodes standard or url-safe base64, padding optional. Returns the length or -1.
int b64_std_decode(const char *in, size_t n, uint8_t *out) {
  while (n && in[n - 1] == '=') n--;
  int o = 0;
  uint32_t acc = 0;
  int bits = 0;
  for (size_t i = 0; i < n; i++) {
    int v = dec_val(in[i]);
    if (v < 0) return -1;
    acc = acc << 6 | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = acc >> bits;
    }
  }
  return o;
}

// ---- tokens
static hmac_mid jwt_key;
static const char JWT_HEAD[] = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";  // {"alg":"HS256","typ":"JWT"}

void hmac_jwt_init(const char *secret, size_t len) { hmac_setup(&jwt_key, secret, len); }

bool ct_eq(const char *a, const char *b, size_t n) {
  unsigned char d = 0;
  for (size_t i = 0; i < n; i++) d |= a[i] ^ b[i];
  return d == 0;
}

// Finds "key": in a flat JSON object; returns the value start or NULL.
static const char *json_key(const char *s, size_t n, const char *key) {
  size_t kl = strlen(key);
  for (size_t i = 0; i + kl + 2 < n; i++) {
    if (s[i] == '"' && !memcmp(s + i + 1, key, kl) && s[i + 1 + kl] == '"') {
      size_t j = i + kl + 2;
      while (j < n && (s[j] == ' ' || s[j] == ':')) j++;
      return j < n ? s + j : NULL;
    }
  }
  return NULL;
}

bool jwt_verify(const char *tok, size_t len, int64_t *sub) {
  if (len < 40 || len > 1024) return false;
  const char *d1 = memchr(tok, '.', len);
  if (!d1) return false;
  size_t hl = d1 - tok;
  const char *d2 = memchr(d1 + 1, '.', len - hl - 1);
  if (!d2 || d2 + 44 != tok + len) return false;  // 32-byte signature is 43 chars
  uint8_t mac[32], got[33];
  hmac_run(&jwt_key, tok, d2 - tok, mac);
  if (b64_std_decode(d2 + 1, 43, got) != 32) return false;
  if (!ct_eq((char *)mac, (char *)got, 32)) return false;
  // Our header is checked by bytes; any other header that still signs correctly must say HS256.
  char jb[1024];
  if (!(hl == sizeof JWT_HEAD - 1 && !memcmp(tok, JWT_HEAD, hl))) {
    int hn = b64_std_decode(tok, hl, (uint8_t *)jb);
    if (hn <= 0) return false;
    const char *alg = json_key(jb, hn, "alg");
    if (!alg || jb + hn - alg < 7 || memcmp(alg, "\"HS256\"", 7)) return false;
  }
  int pn = b64_std_decode(d1 + 1, d2 - d1 - 1, (uint8_t *)jb);
  if (pn <= 0) return false;
  const char *e = json_key(jb, pn, "exp"), *s = json_key(jb, pn, "sub");
  if (!e || !s) return false;
  int64_t exp = 0;
  const char *end = jb + pn;
  if (e >= end || *e < '0' || *e > '9') return false;
  for (; e < end && *e >= '0' && *e <= '9'; e++) exp = exp * 10 + (*e - '0');
  if (exp <= time(NULL)) return false;
  if (s >= end || *s != '"') return false;
  s++;
  int64_t id = 0;
  int digits = 0;
  for (; s < end && *s >= '0' && *s <= '9' && digits < 18; s++, digits++) id = id * 10 + (*s - '0');
  if (!digits || s >= end || *s != '"') return false;
  *sub = id;
  return true;
}

size_t jwt_issue(int64_t uid, char *out) {
  long now = time(NULL);
  char pl[96];
  int pn = snprintf(pl, sizeof pl, "{\"sub\":\"%lld\",\"iat\":%ld,\"exp\":%ld}", (long long)uid, now, now + 30 * 86400);
  memcpy(out, JWT_HEAD, sizeof JWT_HEAD - 1);
  char *o = out + sizeof JWT_HEAD - 1;
  *o++ = '.';
  o += enc(B64U, (uint8_t *)pl, pn, o, false);
  uint8_t mac[32];
  hmac_run(&jwt_key, out, o - out, mac);
  *o++ = '.';
  o += enc(B64U, mac, 32, o, false);
  return o - out;
}
