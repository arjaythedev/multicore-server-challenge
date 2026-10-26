// Shared types for the Conduit server.
#pragma once
#define _GNU_SOURCE
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <libpq-fe.h>

#define likely(x)   __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)

void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));

// ---- growable byte buffer ----
typedef struct {
  char *p;
  size_t len, cap;
} buf_t;

void buf_grow(buf_t *b, size_t need);
static inline char *buf_room(buf_t *b, size_t n) {
  if (unlikely(b->len + n > b->cap)) buf_grow(b, b->len + n);
  return b->p + b->len;
}
static inline void buf_put(buf_t *b, const void *s, size_t n) {
  memcpy(buf_room(b, n), s, n);
  b->len += n;
}
static inline void buf_putc(buf_t *b, char c) {
  *buf_room(b, 1) = c;
  b->len++;
}
#define buf_lit(b, s) buf_put((b), (s), sizeof(s) - 1)
void buf_u64(buf_t *b, uint64_t v);
void buf_i64(buf_t *b, int64_t v);

// ---- a string slice; n < 0 means absent or JSON null ----
typedef struct {
  const char *p;
  int n;
} str_t;
#define STR_NONE ((str_t){NULL, -1})

// ---- event loop objects (the first field of everything epoll points at) ----
enum { K_LISTEN = 1, K_CONN, K_PG, K_EVENT };

typedef struct loop loop_t;
typedef struct conn conn_t;
typedef struct job job_t;
typedef void (*job_fn)(job_t *);

struct conn {
  int kind;
  int fd;
  loop_t *L;
  buf_t in;          // received, not yet handled
  buf_t out;         // response bytes not yet accepted by the socket
  size_t outoff;
  job_t *job;        // the request being served, or NULL
  bool close_after;  // close once the output is sent
  bool dead;         // socket closed while a job was running
};

#define MAXRES 4
#define MAXF 8
struct job {
  loop_t *L;
  conn_t *c;
  char *req;                // owned copy of the request: every str_t below points into it or into sbuf
  char *sbuf;               // decoded strings (owned)
  int64_t viewer;
  str_t token;
  str_t seg[6];             // path segments after /api/, percent-decoded
  int nseg;
  str_t f[MAXF];            // body fields or filters, per route
  int64_t num[4];
  char nb[4][24];           // numbers formatted as statement parameters
  char *tags;               // tagList as a Postgres text[] literal (owned), or NULL
  char *hash;               // bcrypt output (owned), or NULL
  int ok;                   // bcrypt verify result
  bool keep_alive;
  PGresult *res[MAXRES];
  int nres;
  int pgi;                  // the Postgres connection this job's statements went to
  // batched reads: the request's parameters (NUL-terminated text), and where its rows are in the shared
  // result (R rows r0 .. r0+rn-1; column 0 is the request's ordinal)
  const char *bv[4];
  PGresult *R;
  int r0, rn;
  struct batch *bat;
  long seq;                 // arrival number in the batch queue
  int64_t t_us;             // arrival time in the batch queue (CLOCK_MONOTONIC)
  char *bc_pw;              // bcrypt task: password (owned, NUL-terminated)
  char *bc_set;             // stored hash to verify against (owned), or NULL to make a new hash
  job_fn next;              // called when the results (or the bcrypt result) are in
  job_t *link;              // mailbox / queue link
};

// ---- batched read kinds (handlers.c defines BKINDS) ----
enum { B_ART, B_CMT, B_TAGS, B_PROF, B_LALL, B_LTAG, B_LAUTH, B_LFAV, B_FEED, NBK };
typedef struct {
  int stmt;
  const char *types;  // one char per array parameter: 'i' integer, 't' text; "" = just a count
  int shared_stmt;    // if > 0 and sharing is on: one execution whose single row every waiting request gets
} bkind_t;
extern int share_reads;
extern const bkind_t BKINDS[];

// ---- per-thread loop ----
typedef struct pgc pgc_t;
struct loop {
  int id;
  int ep;
  int lfd_kind, lfd;         // listener (kind tag first for epoll)
  int ev_kind, evfd;         // eventfd for bcrypt results
  pgc_t *pg;
  int npg;                   // read connections pg[0..npg), then npw write connections
  int npw;
  int pg_rr;
  buf_t body;                // response body scratch
  buf_t tmp;                 // misc scratch
  pthread_mutex_t mbx_mu;
  job_t *mbx;                // finished bcrypt jobs
  long paused;               // listener removed (out of descriptors) at this time, or 0
  job_t *bq_head[NBK], *bq_tail[NBK];  // reads waiting to be batched
  long seq;
  int bq_n;                             // total waiting
  int bq_cnt[NBK];                      // waiting per kind
  int64_t next_due;                     // when a waiting kind's window ends (0: nothing waits on a timer)
  int ndirty;
  pgc_t **dirty;             // Postgres connections with queued output
};

// ---- pg.c ----
typedef struct {
  const char *sql;
  int nparams;
} stmt_t;
extern const stmt_t STMTS[];
extern const int NSTMTS;

void pg_open(loop_t *L, const char *url, int nr, int nw);
void pg_event(pgc_t *pc, uint32_t ev);
void pg_flush_dirty(loop_t *L);
// Queue statements for a job: pg_begin, pg_q (any number up to MAXRES), pg_end(fn). fn runs when all
// results are in (j->res[0..nres-1]); the results are freed after fn returns.
void pg_begin(job_t *j);
void pg_begin_w(job_t *j);  // same, on a write connection
void pg_q(job_t *j, int stmt, const char *const *vals, const int *lens);
void pg_end(job_t *j, job_fn fn);
// Batched read: fill j->bv per BKINDS[kind].types, then fn runs with j->R / r0 / rn set.
void pg_read(job_t *j, int kind, job_fn fn);
void pg_schedule(loop_t *L);
int64_t pg_wait_us(loop_t *L);  // how long the loop may sleep (-1: no limit)
void batch_release(struct batch *b);

// ---- auth.c ----
void auth_init(const char *secret);
// 1 = valid (sets *uid), 0 = invalid
int jwt_verify(const char *tok, int len, int64_t *uid);
int jwt_issue(char *out, int64_t uid);   // returns length
void bcrypt_start(int nthreads);
void bcrypt_hash(job_t *j, str_t pw, job_fn fn);                    // -> j->hash
void bcrypt_check(job_t *j, str_t pw, const char *hash, job_fn fn); // -> j->ok
void mbx_drain(loop_t *L);

// ---- bcrypt.c ----
#define BC_MAXLANES 8
typedef struct {
  int cost;
  char prefix[7];     // "$2b$10$"
  char salt_txt[22];  // salt as libxcrypt writes it
  uint32_t salt[4];
  uint32_t key[18];
  char out[61];       // result
  char setting[30];   // self-test only
} bc_req_t;
int bc_prepare(bc_req_t *q, const char *pw, const char *setting);  // 0 = can be computed here
void bc_compute(bc_req_t *q, int n);  // n prepared requests with one cost
int bc_selftest(int rounds);

// ---- json.c ----
// Parse body as {"<wrap>": {...}}; for each name in keys, fill out[i]: n >= 0 for a string (decoded into
// *sb), JSON_NULL for absent/null, JSON_BAD for another type. Array fields (arr_key) are returned as a
// Postgres text[] literal in *arr (NULL if absent/null). Returns false if the body is invalid.
#define JSON_NULL (-1)
#define JSON_BAD (-2)
bool json_wrapper(const char *body, size_t len, const char *wrap, const char *const *keys, int nkeys,
                  str_t *out, char **sb, const char *arr_key, char **arr, bool *arr_bad);
bool json_get(const char *s, size_t n, const char *key, int *t, const char **vp, int *vn, char *dec, int decmax);
void json_str(buf_t *b, const char *s, size_t n);
void json_nstr(buf_t *b, const char *s, size_t n, bool isnull);
void json_ts(buf_t *b, int64_t pg_us);

// ---- main.c ----
void job_reply(job_t *j, int status);     // send j->L->body as the response, finish the job
void job_error(job_t *j, int status, const char *msg);
void job_free(job_t *j);

// ---- handlers.c ----
void route(job_t *j, const char *method, int mlen, const char *path, int plen, const char *query, int qlen,
           const char *body, size_t blen, str_t auth);
