// JWT (HS256) and the bcrypt thread pool. HMAC-SHA256 uses OpenSSL's SHA-256 with the key's inner and outer
// states computed once at startup. bcrypt (bcrypt.c, libxcrypt for other formats) runs on its own threads
// so the event loops never block on it; a finished job goes back to its loop through a mailbox and an
// eventfd.
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
static pthread_cond_t bq_cv;  // CLOCK_MONOTONIC, set up in bcrypt_start
static job_t *bq_head, *bq_tail;
static int bq_n;

int bcrypt_nice = 10;
int bcrypt_lanes = 4;
int bcrypt_window_ms = 150;
long dbg_bc_groups, dbg_bc_hashes;  // DEBUG_LOOP counters

// libxcrypt, for hashes bcrypt.c doesn't take (other formats, $2a$ with 8-bit passwords)
static void bc_slow(job_t *j, const char *setting, struct crypt_data *cd) {
  char *h = crypt_rn(j->bc_pw, setting, cd, sizeof *cd);
  if (!j->bc_set) {
    if (!h) die("crypt failed");
    j->hash = strdup(h);
  } else {
    size_t n = strlen(j->bc_set);
    j->ok = h && strlen(h) == n && CRYPTO_memcmp(h, j->bc_set, n) == 0;
  }
}

static void bc_done(job_t *j) {
  loop_t *L = j->L;
  pthread_mutex_lock(&L->mbx_mu);
  j->link = L->mbx;
  L->mbx = j;
  pthread_mutex_unlock(&L->mbx_mu);
  uint64_t one = 1;
  if (write(L->evfd, &one, 8) < 0) {}
}

static void *bcrypt_worker(void *arg) {
  // Worker 0 takes whatever is queued. The others only start when two full batches are waiting: one
  // thread with several lanes keeps up with the usual login rate (and fills its lanes better alone), the
  // rest are spare capacity for when it falls behind.
  bool helper = (intptr_t)arg != 0;
  // Hashing yields to request handling and Postgres when the CPU is contended: a login waits a little
  // longer instead of every other request waiting behind it.
  if (bcrypt_nice) setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), bcrypt_nice);
  struct crypt_data *cd = calloc(1, sizeof *cd);
  for (;;) {
    // take up to bcrypt_lanes queued jobs: they are computed together (see bcrypt.c). Worker 0 never
    // waits for a batch to fill; batches fill up by themselves while it is busy.
    job_t *jobs[BC_MAXLANES];
    int nj = 0;
    pthread_mutex_lock(&bq_mu);
    while (helper ? bq_n < 2 * bcrypt_lanes : bq_n == 0) pthread_cond_wait(&bq_cv, &bq_mu);
    if (!helper && bq_n < bcrypt_lanes && bcrypt_window_ms > 0) {
      // let the batch fill: the oldest job waits up to bcrypt_window_ms for others (logins are ~0.1% of
      // requests, so at moderate load a batch would otherwise nearly always run one lane)
      int64_t dl = bq_head->t_us + (int64_t)bcrypt_window_ms * 1000;
      struct timespec ts = {dl / 1000000, (dl % 1000000) * 1000};
      while (bq_n < bcrypt_lanes && pthread_cond_timedwait(&bq_cv, &bq_mu, &ts) == 0) {}
    }
    while (bq_head && nj < bcrypt_lanes) {
      jobs[nj++] = bq_head;
      bq_head = bq_head->link;
      bq_n--;
    }
    if (!bq_head) bq_tail = NULL;
    pthread_mutex_unlock(&bq_mu);

    bc_req_t q[BC_MAXLANES];
    job_t *qj[BC_MAXLANES];
    int nq = 0;
    for (int i = 0; i < nj; i++) {
      job_t *j = jobs[i];
      char salt[CRYPT_GENSALT_OUTPUT_SIZE];
      const char *setting = j->bc_set;
      if (!setting) {
        if (!crypt_gensalt_rn("$2b$", 10, NULL, 0, salt, sizeof salt)) die("crypt_gensalt failed");
        setting = salt;
      }
      if (bc_prepare(&q[nq], j->bc_pw, setting) == 0) qj[nq++] = j;
      else bc_slow(j, setting, cd), bc_done(j);
    }
    // one bc_compute per cost (all requests share cost 10 in practice)
    while (nq > 0) {
      int cost = q[0].cost, m = 0, rest = 0;
      bc_req_t grp[BC_MAXLANES];
      job_t *gj[BC_MAXLANES];
      for (int i = 0; i < nq; i++) {
        if (q[i].cost == cost) grp[m] = q[i], gj[m++] = qj[i];
        else q[rest] = q[i], qj[rest++] = qj[i];
      }
      nq = rest;
      bc_compute(grp, m);
      __atomic_fetch_add(&dbg_bc_groups, 1, __ATOMIC_RELAXED);
      __atomic_fetch_add(&dbg_bc_hashes, m, __ATOMIC_RELAXED);
      for (int i = 0; i < m; i++) {
        job_t *j = gj[i];
        if (!j->bc_set) j->hash = strdup(grp[i].out);
        else j->ok = strlen(j->bc_set) == 60 && CRYPTO_memcmp(grp[i].out, j->bc_set, 60) == 0;
        bc_done(j);
      }
      memset(grp, 0, sizeof grp);
    }
    memset(q, 0, sizeof q);
  }
  return NULL;
}

void bcrypt_start(int n) {
  pthread_condattr_t ca;
  pthread_condattr_init(&ca);
  pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
  pthread_cond_init(&bq_cv, &ca);
  for (int i = 0; i < n; i++) {
    pthread_t t;
    pthread_create(&t, NULL, bcrypt_worker, (void *)(intptr_t)i);
  }
}

static void bq_push(job_t *j) {
  j->link = NULL;
  pthread_mutex_lock(&bq_mu);
  if (bq_tail) bq_tail->link = j;
  else bq_head = j;
  bq_tail = j;
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  j->t_us = (int64_t)now.tv_sec * 1000000 + now.tv_nsec / 1000;
  bq_n++;
  pthread_cond_broadcast(&bq_cv);
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
