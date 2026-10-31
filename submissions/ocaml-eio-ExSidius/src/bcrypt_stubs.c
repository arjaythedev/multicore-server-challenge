/* bcrypt cost 10 on plain threads outside the OCaml runtime, up to LANES hashes at once.

   One hash is a chain of dependent S-box loads, so alone it leaves the core waiting on load latency. Each lane here
   is a whole independent bcrypt state, and every step is done for all lanes back to back: on the benchmark box 4
   lanes cost 17-27 ms of CPU per hash against 51-56 ms alone. The kernel follows c-epoll-umitaltintas, and
   bf_tables.h comes from there; on CPUs with BMI, the cost loop runs hand-scheduled assembly (bcrypt_expand0.c) after
   zig-iouring-nick-potts. Each password gets its own hash and its own salt; nothing is merged or kept.

   The threads run at low priority, so they must never hold anything the rest of the process needs: an OCaml domain
   preempted here would stall every domain's stop-the-world GC, which is why these aren't domains, and callers push
   with a CAS and post a semaphore, so they never wait on a lock one of these threads holds. A finished job signals
   its own eventfd, which the calling fiber awaits. */
#define _GNU_SOURCE
#include <crypt.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include "bf_tables.h"

#define LANES 5
#define COST 10
#define AI static inline __attribute__((always_inline))
#define EACH for (int l = 0; l < n; l++)

typedef struct {
  uint32_t w[18 + 1024]; /* P-array, then the four S-boxes */
} bf_t;

typedef struct job {
  struct job *next;
  atomic_int refs; /* the worker and the caller: the last one out frees it */
  int efd;
  int fast;
  int lone; /* no other login arrived recently, so don't wait for one */
  int64_t arrived_ns;
  char *pw;
  char *setting;
  char prefix[8];     /* "$2b$10$" */
  char salt_txt[23];  /* the salt as libxcrypt writes it */
  uint32_t salt[4];
  uint32_t key[18];
  char out[CRYPT_OUTPUT_SIZE];
} job_t;

#define P(st) ((st)->w)
#define S(st, b) ((st)->w + 18 + 256 * (b))
#define F(st, x) \
  (((S(st, 0)[(x) >> 24] + S(st, 1)[((x) >> 16) & 0xff]) ^ S(st, 2)[((x) >> 8) & 0xff]) + S(st, 3)[(x) & 0xff])

AI void bf_enc(int n, bf_t *st, uint32_t *L, uint32_t *R) {
  EACH L[l] ^= P(&st[l])[0];
  for (int i = 1; i <= 16; i += 2) {
    EACH R[l] ^= F(&st[l], L[l]) ^ P(&st[l])[i];
    EACH L[l] ^= F(&st[l], R[l]) ^ P(&st[l])[i + 1];
  }
  EACH {
    uint32_t t = L[l];
    L[l] = R[l] ^ P(&st[l])[17];
    R[l] = t;
  }
}

/* Rewrites each lane's state with the chained encryption of a zero block; the first expansion also mixes in the salt. */
AI void bf_chain(int n, bf_t *st, uint32_t (*salt)[4]) {
  uint32_t L[LANES] = {0}, R[LANES] = {0};
  for (int i = 0; i < 18 + 1024; i += 2) {
    if (salt) EACH {
      L[l] ^= salt[l][i & 2];
      R[l] ^= salt[l][(i & 2) + 1];
    }
    bf_enc(n, st, L, R);
    EACH {
      st[l].w[i] = L[l];
      st[l].w[i + 1] = R[l];
    }
  }
}

#if defined(__x86_64__)
void conduit_expand0_1(uint32_t *);
void conduit_expand0_2(uint32_t *);
void conduit_expand0_3(uint32_t *);
void conduit_expand0_4(uint32_t *);
void conduit_expand0_5(uint32_t *);
static void (*const expand0_by_n[LANES + 1])(uint32_t *) = {NULL, conduit_expand0_1, conduit_expand0_2, conduit_expand0_3,
                                                            conduit_expand0_4, conduit_expand0_5};
#endif
static int use_asm = 0;

/* One expansion with no salt, the whole of the cost loop. */
AI void chain0(int n, bf_t *st) {
#if defined(__x86_64__)
  if (use_asm) {
    expand0_by_n[n](st->w);
    return;
  }
#endif
  bf_chain(n, st, NULL);
}

AI void eks(int n, bf_t *st, uint32_t (*key)[18], uint32_t (*salt)[4], int cost, uint32_t (*out)[6]) {
  EACH {
    memcpy(P(&st[l]), bf_init_p, sizeof bf_init_p);
    memcpy(S(&st[l], 0), bf_init_s, sizeof bf_init_s);
    for (int i = 0; i < 18; i++) P(&st[l])[i] ^= key[l][i];
  }
  bf_chain(n, st, salt);
  for (uint64_t r = (uint64_t)1 << cost; r; r--) {
    EACH for (int i = 0; i < 18; i++) P(&st[l])[i] ^= key[l][i];
    chain0(n, st);
    EACH for (int i = 0; i < 18; i++) P(&st[l])[i] ^= salt[l][i & 3];
    chain0(n, st);
  }
  static const uint32_t magic[6] = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
  EACH memcpy(out[l], magic, sizeof magic);
  for (int b = 0; b < 6; b += 2) {
    uint32_t L[LANES], R[LANES];
    EACH {
      L[l] = out[l][b];
      R[l] = out[l][b + 1];
    }
    for (int k = 0; k < 64; k++) bf_enc(n, st, L, R);
    EACH {
      out[l][b] = L[l];
      out[l][b + 1] = R[l];
    }
  }
}

typedef void (*eks_fn)(bf_t *, uint32_t (*)[18], uint32_t (*)[4], int, uint32_t (*)[6]);
#define EKS_N(k) \
  static __attribute__((noinline)) void eks##k(bf_t *st, uint32_t (*key)[18], uint32_t (*salt)[4], int cost, uint32_t (*out)[6]) { \
    eks(k, st, key, salt, cost, out); \
  }
EKS_N(1)
EKS_N(2)
EKS_N(3)
EKS_N(4)
EKS_N(5)
static const eks_fn eks_by_n[LANES + 1] = {NULL, eks1, eks2, eks3, eks4, eks5};

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

/* Fills the job's key and salt from "$2?$NN$<22 salt chars>" and returns the cost, or -1 for anything this kernel
   doesn't reproduce exactly, which goes to libxcrypt. */
static int prepare(job_t *j) {
  const char *s = j->setting, *pw = j->pw;
  if (strnlen(s, 29) < 29 || s[0] != '$' || s[1] != '2' || s[3] != '$' || s[6] != '$') return -1;
  if (s[2] != 'a' && s[2] != 'b' && s[2] != 'y') return -1;
  if (s[4] < '0' || s[4] > '3' || s[5] < '0' || s[5] > '9') return -1;
  int cost = (s[4] - '0') * 10 + (s[5] - '0');
  if (cost < 4 || cost > 31) return -1;
  size_t n = strlen(pw);
  if (n > 72) return -1;
  /* libxcrypt's $2a$ has a countermeasure for an old bug with these bytes. */
  if (s[2] == 'a')
    for (size_t i = 0; i < n; i++)
      if ((unsigned char)pw[i] >= 0x80) return -1;
  int v[24] = {0};
  for (int i = 0; i < 22; i++)
    if ((v[i] = b64val((unsigned char)s[7 + i])) < 0) return -1;
  uint8_t salt[16];
  for (int i = 0, o = 0; o < 16; i += 4) {
    salt[o++] = (uint8_t)(v[i] << 2 | v[i + 1] >> 4);
    if (o < 16) salt[o++] = (uint8_t)((v[i + 1] & 15) << 4 | v[i + 2] >> 2);
    if (o < 16) salt[o++] = (uint8_t)((v[i + 2] & 3) << 6 | v[i + 3]);
  }
  memcpy(j->prefix, s, 7);
  for (int i = 0; i < 4; i++)
    j->salt[i] = (uint32_t)salt[4 * i] << 24 | (uint32_t)salt[4 * i + 1] << 16 | (uint32_t)salt[4 * i + 2] << 8 | salt[4 * i + 3];
  b64enc(j->salt_txt, salt, 16);
  /* The password and its NUL, cycled. */
  size_t kn = n + 1 > 72 ? 72 : n + 1, p = 0;
  for (int i = 0; i < 18; i++) {
    uint32_t w = 0;
    for (int b = 0; b < 4; b++) {
      w = w << 8 | (unsigned char)(p < n ? pw[p] : 0);
      p = p + 1 == kn ? 0 : p + 1;
    }
    j->key[i] = w;
  }
  return cost;
}

/* n jobs of one cost. */
static void compute(job_t **jobs, int n, int cost) {
  _Alignas(64) bf_t st[LANES];
  uint32_t key[LANES][18], salt[LANES][4], ct[LANES][6];
  EACH {
    memcpy(key[l], jobs[l]->key, sizeof key[l]);
    memcpy(salt[l], jobs[l]->salt, sizeof salt[l]);
  }
  eks_by_n[n](st, key, salt, cost, ct);
  EACH {
    uint8_t raw[24];
    for (int i = 0; i < 6; i++) {
      raw[4 * i] = (uint8_t)(ct[l][i] >> 24);
      raw[4 * i + 1] = (uint8_t)(ct[l][i] >> 16);
      raw[4 * i + 2] = (uint8_t)(ct[l][i] >> 8);
      raw[4 * i + 3] = (uint8_t)ct[l][i];
    }
    char *o = jobs[l]->out;
    memcpy(o, jobs[l]->prefix, 7);
    memcpy(o + 7, jobs[l]->salt_txt, 22);
    b64enc(o + 29, raw, 23); /* bcrypt drops the last byte */
    o[60] = 0;
  }
  explicit_bzero(st, sizeof st);
  explicit_bzero(key, sizeof key);
}

static void job_release(job_t *j) {
  if (atomic_fetch_sub(&j->refs, 1) != 1) return;
  close(j->efd);
  explicit_bzero(j->pw, strlen(j->pw));
  explicit_bzero(j->key, sizeof j->key);
  explicit_bzero(j->out, sizeof j->out);
  free(j->pw);
  free(j->setting);
  free(j);
}

static void job_finish(job_t *j) {
  eventfd_write(j->efd, 1);
  job_release(j);
}

static int64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static _Atomic(job_t *) incoming = NULL;
static _Atomic int64_t last_arrival = 0;
static atomic_long hashes = 0, batches = 0;
static sem_t wake;
static int64_t wait_ns;
static int nice_level;
/* Jobs in arrival order, owned by whichever worker holds the lock. Callers never take it. */
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static job_t *head = NULL, *tail = NULL;
static int queued = 0;

static void drain_incoming(void) {
  job_t *rev = atomic_exchange(&incoming, NULL), *fifo = NULL;
  while (rev) {
    job_t *next = rev->next;
    rev->next = fifo;
    fifo = rev;
    rev = next;
  }
  while (fifo) {
    job_t *next = fifo->next;
    fifo->next = NULL;
    if (tail) tail->next = fifo; else head = fifo;
    tail = fifo;
    queued++;
    fifo = next;
  }
}

static job_t *pop(void) {
  job_t *j = head;
  head = j->next;
  if (!head) tail = NULL;
  queued--;
  return j;
}

static void *worker(void *arg) {
  (void)arg;
  setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), nice_level);
  struct crypt_data *cd = calloc(1, sizeof *cd);
  if (!cd) abort();
  pthread_mutex_lock(&mu);
  for (;;) {
    drain_incoming();
    if (!head) {
      pthread_mutex_unlock(&mu);
      sem_wait(&wake);
      pthread_mutex_lock(&mu);
      continue;
    }
    job_t *jobs[LANES];
    int n = 0;
    if (!head->fast) {
      jobs[n++] = pop();
    } else {
      int fast_ready = 0;
      for (job_t *j = head; j && j->fast && fast_ready < LANES; j = j->next) fast_ready++;
      int blocked = fast_ready < queued; /* a slow job behind them: don't hold it up */
      int64_t deadline = head->arrived_ns + wait_ns;
      if (fast_ready < LANES && !head->lone && !blocked && now_ns() < deadline) {
        pthread_mutex_unlock(&mu);
        struct timespec t = {deadline / 1000000000, deadline % 1000000000};
        sem_clockwait(&wake, CLOCK_MONOTONIC, &t);
        pthread_mutex_lock(&mu);
        continue;
      }
      while (n < fast_ready) jobs[n++] = pop();
    }
    if (head) sem_post(&wake); /* what's left is another worker's */
    pthread_mutex_unlock(&mu);
    if (jobs[0]->fast) {
      compute(jobs, n, COST);
    } else {
      const char *h = crypt_r(jobs[0]->pw, jobs[0]->setting, cd);
      if (h && h[0] != '*') strncpy(jobs[0]->out, h, sizeof jobs[0]->out - 1);
      explicit_bzero(cd, sizeof *cd);
    }
    atomic_fetch_add(&hashes, n);
    atomic_fetch_add(&batches, 1);
    for (int l = 0; l < n; l++) job_finish(jobs[l]);
    pthread_mutex_lock(&mu);
  }
  return NULL;
}

/* Checks every batch width against libxcrypt, at a low cost so that it takes about a millisecond each. */
static int selftest(void) {
  static const char *pws[] = {"", "a", "password123", "012345678901234567890123456789012345678901234567890123456789012345678901"};
  static const char *settings[] = {"$2b$04$abcdefghijklmnopqrstuu", "$2a$04$./ABCDEFGHIJKLMNOPQRSTUV", "$2y$04$zyxwvutsrqponmlkjihgfe", "$2b$04$0123456789abcdefghijkl", "$2b$04$NMLKJIHGFEDCBA9876543u"};
  struct crypt_data *cd = calloc(1, sizeof *cd);
  if (!cd) return 0;
  int ok = 1;
  for (int n = 1; n <= LANES; n++) {
    job_t store[LANES];
    job_t *jobs[LANES];
    memset(store, 0, sizeof store);
    EACH {
      store[l].pw = (char *)pws[(l + n) % 4];
      store[l].setting = (char *)settings[l % 5];
      jobs[l] = &store[l];
      if (prepare(jobs[l]) != 4) ok = 0;
    }
    if (ok) compute(jobs, n, 4);
    EACH {
      const char *h = crypt_r(store[l].pw, store[l].setting, cd);
      if (!h || strcmp(h, store[l].out) != 0) ok = 0;
    }
  }
  free(cd);
  return ok;
}

CAMLprim value conduit_bcrypt_start(value threads, value wait_ms, value nice) {
  CAMLparam3(threads, wait_ms, nice);
#if defined(__x86_64__)
  use_asm = __builtin_cpu_supports("bmi") && __builtin_cpu_supports("bmi2");
#endif
  if (!selftest()) caml_failwith("bcrypt: the kernel disagrees with libxcrypt");
  wait_ns = (int64_t)Long_val(wait_ms) * 1000000;
  nice_level = Int_val(nice);
  if (sem_init(&wake, 0, 0) != 0) caml_failwith("bcrypt: sem_init");
  /* Signals stay with the domains. */
  sigset_t all, old;
  sigfillset(&all);
  pthread_sigmask(SIG_BLOCK, &all, &old);
  for (long i = 0; i < Long_val(threads); i++) {
    pthread_t t;
    if (pthread_create(&t, NULL, worker, NULL) != 0) caml_failwith("bcrypt: pthread_create");
    pthread_detach(t);
  }
  pthread_sigmask(SIG_SETMASK, &old, NULL);
  CAMLreturn(Val_unit);
}

/* Queues a hash and returns the job as an immediate: malloc alignment leaves the low bit free. An empty setting means
   a new password, with a fresh salt. */
CAMLprim value conduit_bcrypt_submit(value pw, value setting) {
  job_t *j = calloc(1, sizeof *j);
  if (!j) caml_failwith("bcrypt: out of memory");
  j->pw = strdup(String_val(pw));
  char fresh[CRYPT_GENSALT_OUTPUT_SIZE];
  const char *s = String_val(setting);
  if (caml_string_length(setting) == 0) s = crypt_gensalt_rn("$2b$", COST, NULL, 0, fresh, sizeof fresh);
  j->setting = s ? strdup(s) : NULL;
  j->efd = eventfd(0, EFD_CLOEXEC);
  if (!j->pw || !j->setting || j->efd < 0) caml_failwith("bcrypt: submit failed");
  atomic_init(&j->refs, 2);
  j->fast = prepare(j) == COST;
  int64_t now = now_ns();
  j->arrived_ns = now;
  j->lone = now - atomic_exchange(&last_arrival, now) >= wait_ns;
  job_t *top = atomic_load(&incoming);
  do j->next = top; while (!atomic_compare_exchange_weak(&incoming, &top, j));
  sem_post(&wake);
  return (value)j | 1;
}

#define JOB(v) ((job_t *)((v) & ~(value)1))

CAMLprim value conduit_bcrypt_fd(value job) { return Val_int(JOB(job)->efd); }
CAMLprim value conduit_bcrypt_result(value job) { return caml_copy_string(JOB(job)->out); }
CAMLprim value conduit_bcrypt_release(value job) { job_release(JOB(job)); return Val_unit; }
CAMLprim value conduit_bcrypt_hashes(value unit) { (void)unit; return Val_long(atomic_load(&hashes)); }
CAMLprim value conduit_bcrypt_batches(value unit) { (void)unit; return Val_long(atomic_load(&batches)); }
