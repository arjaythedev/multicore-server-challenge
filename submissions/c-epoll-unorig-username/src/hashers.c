// bcrypt runs on its own threads, never on a loop or a database thread. Each takes whatever is waiting, up to the lane
// count, and hashes those in lockstep.
#include <pthread.h>
#include <stdio.h>

#include "common.h"

static pthread_mutex_t q_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_cv = PTHREAD_COND_INITIALIZER;
static job *q_head, *q_tail;
static int lanes = 4;

static void push(job *j) {
  j->next = NULL;
  pthread_mutex_lock(&q_mu);
  if (q_tail) q_tail->next = j;
  else q_head = j;
  q_tail = j;
  pthread_cond_signal(&q_cv);
  pthread_mutex_unlock(&q_mu);
}

void hash_enqueue_verify(job *j, const char *stored, size_t sl) {
  // The pool reserved room for the stored hash after the request's own fields.
  char *s = (char *)j->s4;
  if (sl > 100) sl = 0;
  memcpy(s, stored, sl);
  s[sl] = 0;
  j->l4 = sl;
  push(j);
}

void hash_enqueue_new(job *j) { push(j); }

static void *hasher_main(void *arg) {
  (void)arg;
  job *g[BCRYPT_MAX_LANES];
  const char *pw[BCRYPT_MAX_LANES], *set[BCRYPT_MAX_LANES];
  size_t pl[BCRYPT_MAX_LANES];
  char out[BCRYPT_MAX_LANES][BCRYPT_LEN + 1], salts[BCRYPT_MAX_LANES][30];
  buf_t O = {0};
  for (;;) {
    pthread_mutex_lock(&q_mu);
    while (!q_head) pthread_cond_wait(&q_cv, &q_mu);
    int n = 0;
    while (q_head && n < lanes) {
      g[n++] = q_head;
      q_head = q_head->next;
    }
    if (!q_head) q_tail = NULL;
    pthread_mutex_unlock(&q_mu);
    for (int i = 0; i < n; i++) {
      job *j = g[i];
      if (j->kind == K_LOGIN) {
        pw[i] = j->s2;
        pl[i] = j->l2;
        set[i] = j->s4;
      } else {
        pw[i] = j->s3;
        pl[i] = j->l3;
        bcrypt_gen_salt(salts[i]);
        set[i] = salts[i];
      }
    }
    bcrypt_lanes(n, pw, pl, set, out);
    for (int i = 0; i < n; i++) {
      job *j = g[i];
      if (j->kind == K_LOGIN) {
        if (j->l4 != BCRYPT_LEN || !out[i][0] || !ct_eq(out[i], j->s4, BCRYPT_LEN)) {
          free(j->resp);
          j->resp = NULL;
          job_error(j, 401, "unauthorized");
          continue;
        }
        char tok[256];
        size_t tl = jwt_issue(j->id, tok);
        O.n = 0;
        buf_put(&O, j->resp, j->resp_len);
        buf_put(&O, tok, tl);
        buf_lit(&O, "\"}}");
        free(j->resp);
        job_reply(j, 200, O.p, O.n);
      } else {
        memcpy((char *)j->s4, out[i], BCRYPT_LEN + 1);
        j->l4 = BCRYPT_LEN;
        write_enqueue(j);
      }
    }
  }
  return NULL;
}

void hashers_start(int n) {
  const char *e = getenv("BCRYPT_LANES");
  if (e) lanes = atoi(e);
  if (lanes < 1) lanes = 1;
  if (lanes > BCRYPT_MAX_LANES) lanes = BCRYPT_MAX_LANES;
  for (int i = 0; i < n; i++) {
    pthread_t t;
    pthread_create(&t, NULL, hasher_main, NULL);
  }
}
