// JWT (HS256) and bcrypt. HMAC-SHA256 uses OpenSSL's SHA-256 with the key's inner and outer states
// computed once at startup. bcrypt (libxcrypt) runs on its own threads so the event loops never block on
// it; a finished job goes back to its loop through a mailbox and an eventfd.
#include "app.h"

#include <crypt.h>
#include <openssl/crypto.h>
#include <openssl/sha.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/syscall.h>

enum { J_STR = 1, J_NUM, J_NULL, J_BOOL, J_OBJ, J_ARR };

static SHA256_CTX h_in, h_out;

void auth_init(const char *secret) {
  unsigned char key[64] = {0}, pad[64];
  size_t n = strlen(secret);
  if (n > 64) SHA256((const unsigned char *)secret, n, key);
  else memcpy(key, secret, n);
  for (int i = 0; i < 64; i++) pad[i] = key[i] ^ 0x36;
  SHA256_Init(&h_in);
  SHA256_Update(&h_in, pad, 64);
  for (int i = 0; i < 64; i++) pad[i] = key[i] ^ 0x5c;
  SHA256_Init(&h_out);
  SHA256_Update(&h_out, pad, 64);
}

static void hmac(const char *msg, size_t n, unsigned char out[32]) {
  SHA256_CTX c = h_in;
  SHA256_Update(&c, msg, n);
  SHA256_Final(out, &c);
  c = h_out;
  SHA256_Update(&c, out, 32);
  SHA256_Final(out, &c);
}

static const char B64U[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static int b64u_enc(char *o, const unsigned char *s, int n) {
  char *start = o;
  int i = 0;
  for (; i + 3 <= n; i += 3) {
    unsigned v = s[i] << 16 | s[i + 1] << 8 | s[i + 2];
    *o++ = B64U[v >> 18];
    *o++ = B64U[v >> 12 & 63];
    *o++ = B64U[v >> 6 & 63];
    *o++ = B64U[v & 63];
  }
  if (n - i == 1) {
    unsigned v = s[i] << 16;
    *o++ = B64U[v >> 18];
    *o++ = B64U[v >> 12 & 63];
  } else if (n - i == 2) {
    unsigned v = s[i] << 16 | s[i + 1] << 8;
    *o++ = B64U[v >> 18];
    *o++ = B64U[v >> 12 & 63];
    *o++ = B64U[v >> 6 & 63];
  }
  return o - start;
}

static int b64u_val(int c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '-') return 62;
  if (c == '_') return 63;
  return -1;
}

// unpadded base64url -> bytes; -1 if invalid
static int b64u_dec(unsigned char *o, const char *s, int n) {
  if (n % 4 == 1) return -1;
  unsigned acc = 0;
  int bits = 0, k = 0;
  for (int i = 0; i < n; i++) {
    int v = b64u_val((unsigned char)s[i]);
    if (v < 0) return -1;
    acc = acc << 6 | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      o[k++] = acc >> bits & 0xff;
    }
  }
  return k;
}

static const char JWT_HEAD[] = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";  // {"alg":"HS256","typ":"JWT"}

int jwt_issue(char *out, int64_t uid) {
  char claims[128];
  long now = (long)time(NULL);
  int cn = snprintf(claims, sizeof claims, "{\"sub\":\"%lld\",\"iat\":%ld,\"exp\":%ld}", (long long)uid, now,
                    now + 30L * 24 * 3600);
  char *o = out;
  memcpy(o, JWT_HEAD, sizeof JWT_HEAD - 1);
  o += sizeof JWT_HEAD - 1;
  *o++ = '.';
  o += b64u_enc(o, (unsigned char *)claims, cn);
  unsigned char mac[32];
  hmac(out, o - out, mac);
  *o++ = '.';
  o += b64u_enc(o, mac, 32);
  return o - out;
}

static bool num_val(const char *p, int n, double *d) {
  char t[64];
  if (n <= 0 || n >= 64) return false;
  memcpy(t, p, n);
  t[n] = 0;
  *d = strtod(t, NULL);
  return true;
}

int jwt_verify(const char *tok, int len, int64_t *uid) {
  if (len <= 0 || len > 4096) return 0;
  const char *d1 = memchr(tok, '.', len);
  if (!d1) return 0;
  const char *d2 = memchr(d1 + 1, '.', tok + len - d1 - 1);
  if (!d2 || memchr(d2 + 1, '.', tok + len - d2 - 1)) return 0;
  // signature first: it is the cheapest way to reject a forgery
  unsigned char sig[48], mac[32];
  if (tok + len - d2 - 1 != 43) return 0;
  if (b64u_dec(sig, d2 + 1, tok + len - d2 - 1) != 32) return 0;
  hmac(tok, d2 - tok, mac);
  if (CRYPTO_memcmp(sig, mac, 32) != 0) return 0;
  // header: alg must be HS256
  unsigned char js[3072];
  char dec[256];
  int hn = b64u_dec(js, tok, d1 - tok);
  if (hn < 0) return 0;
  int t;
  const char *vp;
  int vn;
  if (!json_get((char *)js, hn, "alg", &t, &vp, &vn, dec, sizeof dec)) return 0;
  if (t != J_STR || vn != 5 || memcmp(vp, "HS256", 5) != 0) return 0;
  // claims
  int cn = b64u_dec(js, d1 + 1, d2 - d1 - 1);
  if (cn < 0) return 0;
  double now = (double)time(NULL);
  double v;
  if (!json_get((char *)js, cn, "exp", &t, &vp, &vn, dec, sizeof dec)) return 0;
  if (t != J_NUM || !num_val(vp, vn, &v) || !(now < v)) return 0;
  if (!json_get((char *)js, cn, "nbf", &t, &vp, &vn, dec, sizeof dec)) return 0;
  if (t != 0 && (t != J_NUM || !num_val(vp, vn, &v) || now < v)) return 0;
  if (!json_get((char *)js, cn, "iat", &t, &vp, &vn, dec, sizeof dec)) return 0;
  if (t != 0 && t != J_NUM) return 0;
  if (!json_get((char *)js, cn, "sub", &t, &vp, &vn, dec, sizeof dec)) return 0;
  if (t != J_STR || vn < 1 || vn > 19) return 0;
  uint64_t id = 0;
  for (int i = 0; i < vn; i++) {
    if (vp[i] < '0' || vp[i] > '9') return 0;
    id = id * 10 + (vp[i] - '0');
  }
  if (id == 0 || id > (uint64_t)INT64_MAX) return 0;
  *uid = (int64_t)id;
  return 1;
}

// ---- bcrypt pool ----

static pthread_mutex_t bq_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t bq_cv = PTHREAD_COND_INITIALIZER;
static job_t *bq_head, *bq_tail;

int bcrypt_nice = 10;

static void *bcrypt_worker(void *arg) {
  (void)arg;
  // Hashing yields to request handling and Postgres when the CPU is contended: a login waits a little
  // longer instead of every other request waiting behind it.
  if (bcrypt_nice) setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), bcrypt_nice);
  struct crypt_data *cd = calloc(1, sizeof *cd);
  for (;;) {
    pthread_mutex_lock(&bq_mu);
    while (!bq_head) pthread_cond_wait(&bq_cv, &bq_mu);
    job_t *j = bq_head;
    bq_head = j->link;
    if (!bq_head) bq_tail = NULL;
    pthread_mutex_unlock(&bq_mu);

    if (!j->bc_set) {
      char salt[CRYPT_GENSALT_OUTPUT_SIZE];
      if (!crypt_gensalt_rn("$2b$", 10, NULL, 0, salt, sizeof salt)) die("crypt_gensalt failed");
      char *h = crypt_rn(j->bc_pw, salt, cd, sizeof *cd);
      if (!h) die("crypt failed");
      j->hash = strdup(h);
    } else {
      char *h = crypt_rn(j->bc_pw, j->bc_set, cd, sizeof *cd);
      size_t n = strlen(j->bc_set);
      j->ok = h && strlen(h) == n && CRYPTO_memcmp(h, j->bc_set, n) == 0;
    }

    loop_t *L = j->L;
    pthread_mutex_lock(&L->mbx_mu);
    j->link = L->mbx;
    L->mbx = j;
    pthread_mutex_unlock(&L->mbx_mu);
    uint64_t one = 1;
    if (write(L->evfd, &one, 8) < 0) {}
  }
  return NULL;
}

void bcrypt_start(int n) {
  for (int i = 0; i < n; i++) {
    pthread_t t;
    pthread_create(&t, NULL, bcrypt_worker, NULL);
  }
}

static void bq_push(job_t *j) {
  j->link = NULL;
  pthread_mutex_lock(&bq_mu);
  if (bq_tail) bq_tail->link = j;
  else bq_head = j;
  bq_tail = j;
  pthread_cond_signal(&bq_cv);
  pthread_mutex_unlock(&bq_mu);
}

static char *dupn(const char *s, int n) {
  char *d = malloc(n + 1);
  memcpy(d, s, n);
  d[n] = 0;
  return d;
}

void bcrypt_hash(job_t *j, str_t pw, job_fn fn) {
  j->bc_pw = dupn(pw.p, pw.n);
  j->bc_set = NULL;
  j->next = fn;
  bq_push(j);
}

void bcrypt_check(job_t *j, str_t pw, const char *hash, job_fn fn) {
  j->bc_pw = dupn(pw.p, pw.n);
  j->bc_set = strdup(hash);
  j->next = fn;
  bq_push(j);
}

void mbx_drain(loop_t *L) {
  pthread_mutex_lock(&L->mbx_mu);
  job_t *j = L->mbx;
  L->mbx = NULL;
  pthread_mutex_unlock(&L->mbx_mu);
  while (j) {
    job_t *nx = j->link;
    j->next(j);
    j = nx;
  }
}
