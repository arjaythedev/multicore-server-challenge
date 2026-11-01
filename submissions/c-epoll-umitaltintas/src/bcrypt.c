// bcrypt ($2a$, $2b$, $2y$) that computes up to BC_MAXLANES hashes at once in one thread.
//
// A bcrypt hash at cost 10 is about a million Blowfish encryptions. Each round of an encryption is four
// S-box loads whose addresses depend on the previous round, so a single hash spends most of its time
// waiting on load latency while the core's other execution ports sit idle. Here each "lane" is a full,
// independent bcrypt state, and every encryption step is done for all lanes back to back: the chains of
// different lanes overlap, so n hashes take much less than n times as long. The work per hash is exactly
// bcrypt's; only the scheduling changes. (Idea from other entries that interleave bcrypt lanes, see README.)
//
// The Blowfish tables in bf_tables.h are generated from the digits of pi. bc_selftest() checks the output
// against libxcrypt.
#include "app.h"

#include <crypt.h>
#include <stdio.h>
#include <time.h>

#include "bf_tables.h"

typedef struct {
  uint32_t w[18 + 1024];  // P-array (18 words) followed by the four S-boxes (256 words each)
} bf_t;

#define P(st) ((st)->w)
#define S(st, b) ((st)->w + 18 + 256 * (b))
#define F(st, x)                                                                                 \
  (((S(st, 0)[(x) >> 24] + S(st, 1)[((x) >> 16) & 0xff]) ^ S(st, 2)[((x) >> 8) & 0xff]) +       \
   S(st, 3)[(x)&0xff])

#define AI static inline __attribute__((always_inline))
#define LANES _Pragma("GCC unroll 8") for (int l = 0; l < n; l++)

// Encrypts one block (L[l], R[l]) in each of the n lanes.
AI void bf_enc(int n, bf_t *st, uint32_t *L, uint32_t *R) {
  LANES L[l] ^= P(&st[l])[0];
  _Pragma("GCC unroll 8") for (int i = 1; i <= 16; i += 2) {
    LANES R[l] ^= F(&st[l], L[l]) ^ P(&st[l])[i];
    LANES L[l] ^= F(&st[l], R[l]) ^ P(&st[l])[i + 1];
  }
  LANES {
    uint32_t t = L[l];
    L[l] = R[l] ^ P(&st[l])[17];
    R[l] = t;
  }
}

// Rewrites the P-array and S-boxes of each lane with the chained encryption of a zero block. With salt
// (the first expansion only), each block is first XORed with the next 64 bits of the salt, cycling.
AI void bf_chain(int n, bf_t *st, const uint32_t (*salt)[4]) {
  uint32_t L[BC_MAXLANES] = {0}, R[BC_MAXLANES] = {0};
  for (int i = 0; i < 18 + 1024; i += 2) {
    if (salt) {
      LANES {
        L[l] ^= salt[l][i & 2];
        R[l] ^= salt[l][(i & 2) + 1];
      }
    }
    bf_enc(n, st, L, R);
    LANES {
      st[l].w[i] = L[l];
      st[l].w[i + 1] = R[l];
    }
  }
}

// EksBlowfish + 64 encryptions of "OrpheanBeholderScryDoubt". key[l]: the 18 key words (the password
// with its NUL, cycled); salt[l]: the 16 salt bytes as 4 big-endian words. out[l]: the 6 result words.
AI void eks(int n, bf_t *st, const uint32_t (*key)[18], const uint32_t (*salt)[4], int cost,
            uint32_t (*out)[6]) {
  LANES {
    memcpy(P(&st[l]), bf_init_p, sizeof bf_init_p);
    memcpy(S(&st[l], 0), bf_init_s, sizeof bf_init_s);
    for (int i = 0; i < 18; i++) P(&st[l])[i] ^= key[l][i];
  }
  bf_chain(n, st, salt);
  for (uint64_t r = (uint64_t)1 << cost; r; r--) {
    LANES for (int i = 0; i < 18; i++) P(&st[l])[i] ^= key[l][i];
    bf_chain(n, st, NULL);
    LANES for (int i = 0; i < 18; i++) P(&st[l])[i] ^= salt[l][i & 3];
    bf_chain(n, st, NULL);
  }
  static const uint32_t magic[6] = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
  LANES memcpy(out[l], magic, sizeof magic);
  for (int b = 0; b < 6; b += 2) {
    uint32_t L[BC_MAXLANES], R[BC_MAXLANES];
    LANES {
      L[l] = out[l][b];
      R[l] = out[l][b + 1];
    }
    for (int k = 0; k < 64; k++) bf_enc(n, st, L, R);
    LANES {
      out[l][b] = L[l];
      out[l][b + 1] = R[l];
    }
  }
}

#define EKS_N(k)                                                                                     \
  static void eks##k(bf_t *st, const uint32_t (*key)[18], const uint32_t (*salt)[4], int cost,      \
                     uint32_t (*out)[6]) {                                                           \
    eks(k, st, key, salt, cost, out);                                                                \
  }
EKS_N(1)
EKS_N(2)
EKS_N(3)
EKS_N(4)
EKS_N(5)
EKS_N(6)
EKS_N(7)
EKS_N(8)
typedef void (*eks_fn)(bf_t *, const uint32_t (*)[18], const uint32_t (*)[4], int, uint32_t (*)[6]);
static const eks_fn eks_by_n[BC_MAXLANES + 1] = {NULL, eks1, eks2, eks3, eks4, eks5, eks6, eks7, eks8};

// ---- bcrypt's base64 ----

static const char b64[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static int b64val(unsigned char c) {
  if (c == '.') return 0;
  if (c == '/') return 1;
  if (c >= 'A' && c <= 'Z') return c - 'A' + 2;
  if (c >= 'a' && c <= 'z') return c - 'a' + 28;
  if (c >= '0' && c <= '9') return c - '0' + 54;
  return -1;
}

static void b64enc(char *o, const uint8_t *s, int n) {
  for (int i = 0; i < n; i += 3) {
    uint32_t c1 = s[i], c2 = i + 1 < n ? s[i + 1] : 0, c3 = i + 2 < n ? s[i + 2] : 0;
    *o++ = b64[c1 >> 2];
    *o++ = b64[((c1 & 3) << 4) | (c2 >> 4)];
    if (i + 1 >= n) break;
    *o++ = b64[((c2 & 15) << 2) | (c3 >> 6)];
    if (i + 2 >= n) break;
    *o++ = b64[c3 & 63];
  }
}

// 22 characters -> 16 bytes (the last character's low 4 bits are ignored, as in libxcrypt)
static int b64dec_salt(uint8_t out[16], const char *s) {
  int v[24] = {0};
  for (int i = 0; i < 22; i++)
    if ((v[i] = b64val((unsigned char)s[i])) < 0) return -1;
  int o = 0;
  for (int i = 0; o < 16; i += 4) {
    out[o++] = (uint8_t)(v[i] << 2 | v[i + 1] >> 4);
    if (o < 16) out[o++] = (uint8_t)((v[i + 1] & 15) << 4 | v[i + 2] >> 2);
    if (o < 16) out[o++] = (uint8_t)((v[i + 2] & 3) << 6 | v[i + 3]);
  }
  return 0;
}

// ---- requests ----

// Parses the "$2?$NN$<22 salt chars>" prefix of setting. Returns 0 if this implementation can compute the
// hash of pw for it (otherwise the caller uses libxcrypt).
int bc_prepare(bc_req_t *q, const char *pw, const char *setting) {
  if (setting[0] != '$' || setting[1] != '2' || setting[3] != '$' || setting[6] != '$') return -1;
  char minor = setting[2];
  if (minor != 'a' && minor != 'b' && minor != 'y') return -1;
  if (setting[4] < '0' || setting[4] > '3' || setting[5] < '0' || setting[5] > '9') return -1;
  int cost = (setting[4] - '0') * 10 + (setting[5] - '0');
  if (cost < 4 || cost > 31) return -1;
  size_t n = strlen(pw);
  if (n > 72) return -1;  // $2a$ and $2b$ differ past 255 bytes; callers reject over 72 anyway
  // libxcrypt's $2a$ applies a countermeasure for the old sign-extension bug when the password has bytes
  // >= 0x80; leave those to it.
  if (minor == 'a')
    for (size_t i = 0; i < n; i++)
      if ((unsigned char)pw[i] >= 0x80) return -1;
  uint8_t salt[16];
  if (strnlen(setting + 7, 22) < 22 || b64dec_salt(salt, setting + 7) < 0) return -1;

  q->cost = cost;
  memcpy(q->prefix, setting, 7);
  for (int i = 0; i < 4; i++)
    q->salt[i] = (uint32_t)salt[4 * i] << 24 | (uint32_t)salt[4 * i + 1] << 16 |
                 (uint32_t)salt[4 * i + 2] << 8 | salt[4 * i + 3];
  b64enc(q->salt_txt, salt, 16);
  // key stream: the password bytes and its terminating NUL, cycled, 72 bytes at most
  size_t kn = n + 1 > 72 ? 72 : n + 1, p = 0;
  for (int i = 0; i < 18; i++) {
    uint32_t w = 0;
    for (int b = 0; b < 4; b++) {
      w = w << 8 | (unsigned char)(p < n ? pw[p] : 0);
      p = p + 1 == kn ? 0 : p + 1;
    }
    q->key[i] = w;
  }
  return 0;
}

// Computes n (1..BC_MAXLANES) prepared requests that share one cost. q[i].out gets the 60-character hash.
void bc_compute(bc_req_t *q, int n) {
  bf_t st[BC_MAXLANES];
  uint32_t key[BC_MAXLANES][18], salt[BC_MAXLANES][4], ct[BC_MAXLANES][6];
  for (int l = 0; l < n; l++) {
    memcpy(key[l], q[l].key, sizeof key[l]);
    memcpy(salt[l], q[l].salt, sizeof salt[l]);
  }
  eks_by_n[n](st, (const uint32_t(*)[18])key, (const uint32_t(*)[4])salt, q[0].cost, ct);
  for (int l = 0; l < n; l++) {
    uint8_t raw[24];
    for (int i = 0; i < 6; i++) {
      raw[4 * i] = (uint8_t)(ct[l][i] >> 24);
      raw[4 * i + 1] = (uint8_t)(ct[l][i] >> 16);
      raw[4 * i + 2] = (uint8_t)(ct[l][i] >> 8);
      raw[4 * i + 3] = (uint8_t)ct[l][i];
    }
    char *o = q[l].out;
    memcpy(o, q[l].prefix, 7);
    memcpy(o + 7, q[l].salt_txt, 22);
    b64enc(o + 29, raw, 23);  // bcrypt drops the last byte
    o[60] = 0;
  }
  memset(st, 0, sizeof st);
  memset(key, 0, sizeof key);
}

// ---- self-test and timing (bin/conduit --bcrypt-selftest) ----

static uint64_t rnd_state = 0x9e3779b97f4a7c15u;
static uint64_t rnd(void) {
  rnd_state ^= rnd_state << 13;
  rnd_state ^= rnd_state >> 7;
  rnd_state ^= rnd_state << 17;
  return rnd_state;
}

static double now_cpu(void) {
  struct timespec ts;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int bc_selftest(int rounds) {
  rnd_state ^= (uint64_t)time(NULL);
  struct crypt_data *cd = calloc(1, sizeof *cd);
  int bad = 0, total = 0;
  static const char minors[] = "aby";
  for (int r = 0; r < rounds; r++) {
    int n = 1 + (int)(rnd() % BC_MAXLANES), cost = 4 + (int)(rnd() % 3);
    bc_req_t q[BC_MAXLANES];
    char pw[BC_MAXLANES][80];
    for (int l = 0; l < n; l++) {
      int len = (int)(rnd() % 4 == 0 ? 72 - rnd() % 3 : rnd() % 73);
      bool ascii = rnd() % 2;
      for (int i = 0; i < len; i++) pw[l][i] = ascii ? (char)(32 + rnd() % 95) : (char)(1 + rnd() % 255);
      pw[l][len] = 0;
      char minor = minors[rnd() % 3];
      if (minor == 'a' && !ascii) minor = 'b';
      uint8_t s[16];
      for (int i = 0; i < 16; i++) s[i] = (uint8_t)rnd();
      char setting[40];
      snprintf(setting, sizeof setting, "$2%c$%02d$", minor, cost);
      b64enc(setting + 7, s, 16);
      setting[29] = 0;
      // a non-canonical last salt character must come out the way libxcrypt writes it
      if (rnd() % 4 == 0) setting[28] = b64[(b64val((unsigned char)setting[28]) & ~15) | (int)(rnd() % 16)];
      if (bc_prepare(&q[l], pw[l], setting) != 0) {
        fprintf(stderr, "selftest: prepare refused %s\n", setting);
        return 1;
      }
      memcpy(q[l].setting, setting, 30);
    }
    bc_compute(q, n);
    for (int l = 0; l < n; l++) {
      const char *h = crypt_rn(pw[l], q[l].setting, cd, sizeof *cd);
      total++;
      if (!h || strcmp(h, q[l].out) != 0) {
        bad++;
        fprintf(stderr, "selftest MISMATCH lane %d/%d len %zu setting %s\n  ours %s\n  libx %s\n", l, n,
                strlen(pw[l]), q[l].setting, q[l].out, h ? h : "(null)");
      }
    }
  }
  fprintf(stderr, "selftest: %d hashes, %d mismatches\n", total, bad);

  // CPU time per cost-10 hash for each lane count, against libxcrypt
  double t0 = now_cpu();
  for (int i = 0; i < 4; i++) crypt_rn("password123", "$2b$10$abcdefghijklmnopqrstuu", cd, sizeof *cd);
  fprintf(stderr, "libxcrypt: %.1f ms/hash\n", (now_cpu() - t0) / 4 * 1e3);
  for (int n = 1; n <= BC_MAXLANES; n++) {
    bc_req_t q[BC_MAXLANES];
    for (int l = 0; l < n; l++) bc_prepare(&q[l], "password123", "$2b$10$abcdefghijklmnopqrstuu");
    int reps = n < 4 ? 2 : 1;
    t0 = now_cpu();
    for (int k = 0; k < reps; k++) bc_compute(q, n);
    fprintf(stderr, "lanes %d: %.1f ms/hash\n", n, (now_cpu() - t0) / (reps * n) * 1e3);
  }
  free(cd);
  return bad != 0;
}
