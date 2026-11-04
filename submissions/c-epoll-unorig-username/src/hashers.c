// bcrypt runs on its own threads at SCHED_IDLE, using CPU nothing else wants, and hashes in full lanes: a thread starts
// when a full set of lanes is waiting or the oldest job has waited HASH_WAIT_MS. A watchdog at normal priority takes over
// any batch held up too long, starting it again itself, so a saturated box slows logins but never strands them.
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

#include "common.h"

#define LANES BCRYPT_MAX_LANES
static pthread_mutex_t q_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_cv;
static job *q_head, *q_tail;
static int q_n, lanes = 5, wait_us = 150000, waiting;

// A batch in progress. state: 0 = owned by its hasher, 1 = taken by the watchdog, 2 = finished.
typedef struct {
  job *g[LANES];
  int n;
  _Atomic int64_t started;  // 0 = no batch
  _Atomic int state;
} slot_t;
static slot_t *slots;
static int nslots, rescue_after_us = 3000000;

static void push(job *j) {
  j->next = NULL;
  j->t_in = now_us();
  pthread_mutex_lock(&q_mu);
  if (q_tail) q_tail->next = j;
  else q_head = j;
  q_tail = j;
  q_n++;
  if (waiting && (q_n == 1 || q_n >= lanes)) pthread_cond_signal(&q_cv);
  pthread_mutex_unlock(&q_mu);
}

void hash_enqueue_verify(job *j, const char *stored, size_t sl) {
  char *s = (char *)j->s4;  // the request's pool reserved room after its own fields
  if (sl > 100) sl = 0;
  memcpy(s, stored, sl);
  s[sl] = 0;
  j->l4 = sl;
  push(j);
}
void hash_enqueue_new(job *j) { push(j); }

static int take(job **g, slot_t *slot) {
  pthread_mutex_lock(&q_mu);
  for (;;) {
    int64_t now = now_us();
    if (q_n >= lanes || (q_n && now - q_head->t_in >= wait_us)) break;
    waiting++;
    if (q_n) {
      struct timespec ts;
      clock_gettime(CLOCK_MONOTONIC, &ts);
      ts.tv_nsec += (wait_us - (now - q_head->t_in)) * 1000;
      ts.tv_sec += ts.tv_nsec / 1000000000;
      ts.tv_nsec %= 1000000000;
      pthread_cond_timedwait(&q_cv, &q_mu, &ts);
    } else {
      pthread_cond_wait(&q_cv, &q_mu);
    }
    waiting--;
  }
  int n = 0;
  while (q_head && n < lanes) {
    g[n++] = q_head;
    q_head = q_head->next;
  }
  if (!q_head) q_tail = NULL;
  q_n -= n;
  atomic_store(&slot->state, 0);
  slot->n = n;
  memcpy(slot->g, g, sizeof(job *) * n);
  atomic_store(&slot->started, now_us());
  if (q_n >= lanes && waiting) pthread_cond_signal(&q_cv);
  pthread_mutex_unlock(&q_mu);
  return n;
}

typedef struct {
  char pw[LANES][73], set[LANES][64], salts[LANES][30];
  const char *pwp[LANES], *setp[LANES];
  size_t pl[LANES];
  char out[LANES][BCRYPT_LEN + 1];
  buf_t O;
} hctx;

static void compute(hctx *c, job **g, int n) {
  // Copies, so a batch the watchdog took over can't touch its jobs after they are gone.
  for (int i = 0; i < n; i++) {
    job *j = g[i];
    const char *p = j->kind == K_LOGIN ? j->s2 : j->s3;
    size_t l = j->kind == K_LOGIN ? j->l2 : j->l3;
    if (l > 72) l = 72;
    memcpy(c->pw[i], p, l);
    c->pwp[i] = c->pw[i];
    c->pl[i] = l;
    if (j->kind == K_LOGIN) {
      strncpy(c->set[i], j->s4, 63);
      c->set[i][63] = 0;
    } else {
      bcrypt_gen_salt(c->salts[i]);
      memcpy(c->set[i], c->salts[i], 30);
    }
    c->setp[i] = c->set[i];
  }
  bcrypt_lanes(n, c->pwp, c->pl, c->setp, c->out);
}

static void deliver(hctx *c, job **g, int n) {
  for (int i = 0; i < n; i++) {
    job *j = g[i];
    if (j->kind == K_LOGIN) {
      if (j->l4 != BCRYPT_LEN || !c->out[i][0] || !ct_eq(c->out[i], j->s4, BCRYPT_LEN)) {
        free(j->resp);
        j->resp = NULL;
        job_error(j, 401, "unauthorized");
        continue;
      }
      char tok[256];
      size_t tl = jwt_issue(j->id, tok);
      c->O.n = 0;
      buf_put(&c->O, j->resp, j->resp_len);
      buf_put(&c->O, tok, tl);
      buf_lit(&c->O, "\"}}");
      free(j->resp);
      j->resp = NULL;
      job_reply(j, 200, c->O.p, c->O.n);
    } else {
      memcpy((char *)j->s4, c->out[i], BCRYPT_LEN + 1);
      j->l4 = BCRYPT_LEN;
      write_enqueue(j);
    }
  }
}

static void *hasher_main(void *arg) {
  slot_t *slot = arg;
  pthread_setname_np(pthread_self(), "c-hash");
  const char *pol = getenv("HASH_SCHED");
  thread_sched(pol ? pol : "idle", 0);
  hctx *c = calloc(1, sizeof *c);
  job *g[LANES];
  for (;;) {
    int n = take(g, slot);
    compute(c, g, n);
    int want = 0;
    atomic_store(&slot->started, 0);
    if (atomic_compare_exchange_strong(&slot->state, &want, 2)) deliver(c, g, n);
  }
  return NULL;
}

static void *watchdog_main(void *arg) {
  (void)arg;
  hctx *c = calloc(1, sizeof *c);
  for (;;) {
    usleep(50000);
    int64_t now = now_us();
    for (int i = 0; i < nslots; i++) {
      slot_t *s = &slots[i];
      int64_t st = atomic_load(&s->started);
      if (!st || now - st < rescue_after_us) continue;
      int want = 0;
      if (!atomic_compare_exchange_strong(&s->state, &want, 1)) continue;
      job *g[LANES];
      int n = s->n;
      memcpy(g, s->g, sizeof(job *) * n);
      compute(c, g, n);
      deliver(c, g, n);
    }
    // Jobs nobody has started in time: the hashers are starved too.
    pthread_mutex_lock(&q_mu);
    job *g[LANES];
    int n = 0;
    if (q_n && now - q_head->t_in >= rescue_after_us) {
      while (q_head && n < lanes) {
        g[n++] = q_head;
        q_head = q_head->next;
      }
      if (!q_head) q_tail = NULL;
      q_n -= n;
    }
    pthread_mutex_unlock(&q_mu);
    if (n) {
      compute(c, g, n);
      deliver(c, g, n);
    }
  }
  return NULL;
}

void hashers_start(int n) {
  const char *e;
  if ((e = getenv("BCRYPT_LANES"))) lanes = atoi(e);
  if ((e = getenv("HASH_WAIT_MS"))) wait_us = atoi(e) * 1000;
  if ((e = getenv("HASH_RESCUE_MS"))) rescue_after_us = atoi(e) * 1000;
  if (lanes < 1) lanes = 1;
  if (lanes > LANES) lanes = LANES;
  pthread_condattr_t ca;
  pthread_condattr_init(&ca);
  pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
  pthread_cond_init(&q_cv, &ca);
  nslots = n;
  slots = calloc(n, sizeof(slot_t));
  pthread_t t;
  for (int i = 0; i < n; i++) pthread_create(&t, NULL, hasher_main, &slots[i]);
  pthread_create(&t, NULL, watchdog_main, NULL);
}
