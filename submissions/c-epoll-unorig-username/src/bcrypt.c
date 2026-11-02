// bcrypt: EksBlowfish with up to BCRYPT_MAX_LANES hashes interleaved round by round, so their S-box loads fill each
// other's stalls. Every lane runs every round of the key schedule.
#include <stdio.h>
#include <sys/random.h>

#include "bf_consts.h"
#include "common.h"

static const char ALPHA[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

typedef struct __attribute__((aligned(64))) {
  uint32_t w[1042];  // P[18], S[4][256]
  char pad[64 - (1042 * 4) % 64];
} bf_t;

#define F(s, x) \
  ((((s)[18 + ((x) >> 24)] + (s)[18 + 256 + (((x) >> 16) & 255)]) ^ (s)[18 + 512 + (((x) >> 8) & 255)]) + (s)[18 + 768 + ((x) & 255)])

// Encrypts in lockstep across the whole state of each lane, chaining blocks, optionally xoring a salt (16 bytes).
#define FILL(NAME, N)                                                  \
  static void NAME(bf_t *st, const uint32_t (*salt)[4]) {              \
    uint32_t L[N] = {0}, R[N] = {0};                                   \
    int j = 0;                                                         \
    for (int pos = 0; pos < 1042; pos += 2) {                          \
      if (salt) {                                                      \
        for (int l = 0; l < N; l++) {                                  \
          L[l] ^= salt[l][j];                                          \
          R[l] ^= salt[l][j + 1];                                      \
        }                                                              \
        j = (j + 2) & 3;                                               \
      }                                                                \
      for (int l = 0; l < N; l++) L[l] ^= st[l].w[0];                  \
      for (int i = 1; i <= 15; i += 2) {                               \
        for (int l = 0; l < N; l++) R[l] ^= F(st[l].w, L[l]) ^ st[l].w[i]; \
        for (int l = 0; l < N; l++) L[l] ^= F(st[l].w, R[l]) ^ st[l].w[i + 1]; \
      }                                                                \
      for (int l = 0; l < N; l++) {                                    \
        uint32_t t = R[l] ^ st[l].w[17];                               \
        R[l] = L[l];                                                   \
        L[l] = t;                                                      \
        st[l].w[pos] = L[l];                                           \
        st[l].w[pos + 1] = R[l];                                       \
      }                                                                \
    }                                                                  \
  }
FILL(fill1, 1) FILL(fill2, 2) FILL(fill3, 3) FILL(fill4, 4) FILL(fill5, 5) FILL(fill6, 6) FILL(fill7, 7) FILL(fill8, 8)
typedef void (*fill_fn)(bf_t *, const uint32_t (*)[4]);
static const fill_fn fills[9] = {NULL, fill1, fill2, fill3, fill4, fill5, fill6, fill7, fill8};

static inline uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

static void xor_key(bf_t *st, const uint8_t *k, size_t kl) {
  size_t o = 0;
  for (int i = 0; i < 18; i++) {
    uint32_t v = 0;
    for (int b = 0; b < 4; b++) {
      v = v << 8 | k[o];
      o = o + 1 == kl ? 0 : o + 1;
    }
    st->w[i] ^= v;
  }
}

static int dec64(char c) {
  const char *p = c ? strchr(ALPHA, c) : NULL;
  return p ? (int)(p - ALPHA) : -1;
}

// Parses "$2a$NN$<22 salt chars>"; returns the cost or -1.
static int parse_setting(const char *s, uint8_t salt[16]) {
  if (s[0] != '$' || s[1] != '2' || (s[2] != 'a' && s[2] != 'b' && s[2] != 'y') || s[3] != '$' || s[4] < '0' || s[4] > '3' || s[5] < '0' ||
      s[5] > '9' || s[6] != '$')
    return -1;
  int cost = (s[4] - '0') * 10 + s[5] - '0';
  if (cost < 4 || cost > 31) return -1;
  uint32_t acc = 0;
  int bits = 0, o = 0;
  for (int i = 0; i < 22; i++) {
    int v = dec64(s[7 + i]);
    if (v < 0) return -1;
    acc = acc << 6 | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (o < 16) salt[o++] = acc >> bits;
    }
  }
  return cost;
}

static void enc64(const uint8_t *in, int n, char *o) {
  int i = 0;
  while (i < n) {
    uint32_t c1 = in[i++];
    *o++ = ALPHA[c1 >> 2];
    c1 = (c1 & 3) << 4;
    if (i >= n) {
      *o++ = ALPHA[c1];
      break;
    }
    uint32_t c2 = in[i++];
    c1 |= c2 >> 4;
    *o++ = ALPHA[c1];
    c1 = (c2 & 15) << 2;
    if (i >= n) {
      *o++ = ALPHA[c1];
      break;
    }
    c2 = in[i++];
    c1 |= c2 >> 6;
    *o++ = ALPHA[c1];
    *o++ = ALPHA[c2 & 63];
  }
}

void bcrypt_lanes(int n, const char *const pw[], const size_t pl[], const char *const setting[], char out[][BCRYPT_LEN + 1]) {
  uint8_t salts[BCRYPT_MAX_LANES][16], keys[BCRYPT_MAX_LANES][73];
  size_t kl[BCRYPT_MAX_LANES];
  int idx[BCRYPT_MAX_LANES], m = 0, cost = -1;
  for (int i = 0; i < n; i++) {
    out[i][0] = 0;
    int c = parse_setting(setting[i], salts[m]);
    if (c < 0) continue;
    if (cost >= 0 && c != cost) {  // a stored hash of another cost runs on its own
      bcrypt_lanes(1, &pw[i], &pl[i], &setting[i], &out[i]);
      continue;
    }
    cost = c;
    size_t l = pl[i] > 72 ? 72 : pl[i];
    memcpy(keys[m], pw[i], l);
    if (l < 72) keys[m][l++] = 0;
    kl[m] = l;
    idx[m++] = i;
  }
  if (!m) return;
  static __thread bf_t *st;
  if (!st && posix_memalign((void **)&st, 4096, sizeof(bf_t) * BCRYPT_MAX_LANES)) abort();
  uint32_t sw[BCRYPT_MAX_LANES][4];
  for (int l = 0; l < m; l++) {
    memcpy(st[l].w, bf_init, sizeof bf_init);
    for (int i = 0; i < 4; i++) sw[l][i] = be32(salts[l] + i * 4);
    xor_key(&st[l], keys[l], kl[l]);
  }
  fill_fn fill = fills[m];
  fill(st, (const uint32_t(*)[4])sw);
  uint64_t rounds = 1ULL << cost;
  for (uint64_t r = 0; r < rounds; r++) {
    for (int l = 0; l < m; l++) xor_key(&st[l], keys[l], kl[l]);
    fill(st, NULL);
    for (int l = 0; l < m; l++) xor_key(&st[l], salts[l], 16);
    fill(st, NULL);
  }
  static const char MAGIC[] = "OrpheanBeholderScryDoubt";
  for (int l = 0; l < m; l++) {
    uint32_t c[6];
    for (int i = 0; i < 6; i++) c[i] = be32((const uint8_t *)MAGIC + i * 4);
    for (int i = 0; i < 6; i += 2) {
      uint32_t a = c[i], b = c[i + 1];
      const uint32_t *s = st[l].w;
      for (int k = 0; k < 64; k++) {
        a ^= s[0];
        for (int q = 1; q <= 15; q += 2) {
          b ^= F(s, a) ^ s[q];
          a ^= F(s, b) ^ s[q + 1];
        }
        uint32_t t = b ^ s[17];
        b = a;
        a = t;
      }
      c[i] = a;
      c[i + 1] = b;
    }
    uint8_t ct[24];
    for (int i = 0; i < 6; i++) {
      ct[i * 4] = c[i] >> 24;
      ct[i * 4 + 1] = c[i] >> 16;
      ct[i * 4 + 2] = c[i] >> 8;
      ct[i * 4 + 3] = c[i];
    }
    char *o = out[idx[l]];
    memcpy(o, setting[idx[l]], 7);
    enc64(salts[l], 16, o + 7);
    enc64(ct, 23, o + 29);
    o[60] = 0;
  }
}

void bcrypt_gen_salt(char out[30]) {
  uint8_t r[16];
  if (getrandom(r, 16, 0) != 16) abort();
  memcpy(out, "$2a$10$", 7);
  enc64(r, 16, out + 7);
  out[29] = 0;
}

void bcrypt_selftest(void) {
  // Generated with golang.org/x/crypto/bcrypt; every lane count must reproduce them.
  static const struct { const char *pw, *hash; } v[] = {
      {"U*U", "$2a$05$qEcno4Flir2c22Nm4rGCi.2Y8JeOLBjkZAxnxTHm/9YrZfgWtGN2C"},
      {"password123", "$2a$05$.TXTXPTTlrHOYeVHDsAtquvWTXQk6hL6ySn/vgqXMqd3.JBASUs0y"},
      {"", "$2a$05$EAkxz4Y6CKKv6fPAKDNGEuMgeljuLARxxOMuiCe9bIAzFe4bpM9Ei"},
      {"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "$2a$05$4W.SVUbEHKeUMqBREVADuuA76PUIMbh4h20YF2yfeCcKkN0IjGvHS"},
      {"\xc3\xa9\xe2\x82\xac", "$2a$05$LExycA10/7XHu62ZM5Z/1.Eqh6ympIz4jp0pB/qGDuVA6y.Uly96C"},
  };
  for (int n = 1; n <= BCRYPT_MAX_LANES; n++) {
    const char *pw[BCRYPT_MAX_LANES], *set[BCRYPT_MAX_LANES];
    size_t pl[BCRYPT_MAX_LANES];
    char out[BCRYPT_MAX_LANES][BCRYPT_LEN + 1];
    for (int i = 0; i < n; i++) {
      pw[i] = v[i % 5].pw;
      pl[i] = strlen(pw[i]);
      set[i] = v[i % 5].hash;
    }
    bcrypt_lanes(n, pw, pl, set, out);
    for (int i = 0; i < n; i++)
      if (strcmp(out[i], v[i % 5].hash)) {
        fprintf(stderr, "bcrypt selftest failed: lanes %d lane %d got %s\n", n, i, out[i]);
        abort();
      }
  }
}
