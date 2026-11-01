// Postgres through libpq in pipeline mode. Each loop owns a few connections. A request queues its
// statements and one Sync on the least busy connection; results come back in order, so each connection
// keeps a FIFO of jobs and hands a job its results when its Sync result arrives. Output from all jobs
// queued in one event-loop pass goes out in one flush per connection.
#include "app.h"

#include <errno.h>
#include <stdio.h>
#include <sys/epoll.h>
#include <time.h>

struct pgc {
  int kind;
  int fd;
  PGconn *pg;
  loop_t *L;
  job_t **q;
  unsigned qh, qt, qmask;
  int inflight;
  bool dirty;
  bool wantw;
};

static char stmt_name[64][8];

static void pg_watch(pgc_t *pc, bool w) {
  if (pc->wantw == w) return;
  pc->wantw = w;
  struct epoll_event ev = {.events = EPOLLIN | (w ? EPOLLOUT : 0), .data.ptr = pc};
  epoll_ctl(pc->L->ep, EPOLL_CTL_MOD, pc->fd, &ev);
}

// Session settings (rule 2 allows them on our own connections): every statement here has a generic plan as
// good as a custom one, so skip re-planning; no JIT or parallel workers for these small queries. No hash
// aggregation: a generic plan can't see how few distinct keys a batch has and sized each DISTINCT's hash
// table for thousands (8 MB per statement); sorting a few hundred keys is cheaper.
static const char *SESSION_OPTS =
    "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off "
    "-c enable_hashagg=off";

int pg_depth = 1;     // batches in flight per read connection
int batch_max = 256;  // requests per batched statement
long dbg_batches, dbg_batched;  // (debug counters, loop 0)

void pg_open(loop_t *L, const char *url, int nr, int nw) {
  if (NSTMTS > 64) die("too many statements");
  for (int i = 0; i < NSTMTS; i++) snprintf(stmt_name[i], sizeof stmt_name[i], "s%d", i);
  int n = nr + nw;
  L->pg = calloc(n, sizeof(pgc_t));
  L->npg = nr;
  L->npw = nw;
  L->dirty = calloc(n, sizeof(pgc_t *));
  for (int k = 0; k < n; k++) {
    pgc_t *pc = &L->pg[k];
    pc->kind = K_PG;
    pc->L = L;
    // No TLS on the local connection: Postgres would otherwise encrypt every result (sslmode=prefer).
    const char *kw[] = {"dbname", "sslmode", "options", NULL};
    const char *vals[] = {url, "disable", SESSION_OPTS, NULL};
    pc->pg = PQconnectdbParams(kw, vals, 1);
    if (PQstatus(pc->pg) != CONNECTION_OK) die("postgres: %s", PQerrorMessage(pc->pg));
    for (int i = 0; i < NSTMTS; i++) {
      PGresult *r = PQprepare(pc->pg, stmt_name[i], STMTS[i].sql, STMTS[i].nparams, NULL);
      if (PQresultStatus(r) != PGRES_COMMAND_OK)
        die("prepare s%d: %s\n%s", i, PQresultErrorMessage(r), STMTS[i].sql);
      PQclear(r);
    }
    if (PQsetnonblocking(pc->pg, 1) != 0) die("postgres: setnonblocking failed");
    if (PQenterPipelineMode(pc->pg) != 1) die("postgres: pipeline mode failed");
    pc->fd = PQsocket(pc->pg);
    pc->qmask = 4095;
    pc->q = calloc(pc->qmask + 1, sizeof(job_t *));
    struct epoll_event ev = {.events = EPOLLIN, .data.ptr = pc};
    if (epoll_ctl(L->ep, EPOLL_CTL_ADD, pc->fd, &ev) < 0) die("epoll_ctl: %s", strerror(errno));
  }
}

static int pick(loop_t *L, int first, int n) {
  int best = first + L->pg_rr++ % n;
  int load = L->pg[best].inflight;
  for (int k = 1; k < n && load > 0; k++) {
    int i = first + (best - first + k) % n;
    if (L->pg[i].inflight < load) {
      load = L->pg[i].inflight;
      best = i;
    }
  }
  return best;
}

// Reads go to the read connections; writes to their own, so a commit's WAL flush never holds up reads
// queued behind it on a pipelined connection.
void pg_begin(job_t *j) { j->pgi = pick(j->L, 0, j->L->npg); }
void pg_begin_w(job_t *j) { j->pgi = j->L->npw ? pick(j->L, j->L->npg, j->L->npw) : pick(j->L, 0, j->L->npg); }

void pg_q(job_t *j, int stmt, const char *const *vals, const int *lens) {
  pgc_t *pc = &j->L->pg[j->pgi];
  if (!PQsendQueryPrepared(pc->pg, stmt_name[stmt], STMTS[stmt].nparams, vals, lens, NULL, 1))
    die("postgres send: %s", PQerrorMessage(pc->pg));
}

void pg_end(job_t *j, job_fn fn) {
  loop_t *L = j->L;
  pgc_t *pc = &L->pg[j->pgi];
#ifdef LIBPQ_HAS_SEND_PIPELINE_SYNC
  if (!PQsendPipelineSync(pc->pg)) die("postgres sync: %s", PQerrorMessage(pc->pg));
#else
  if (!PQpipelineSync(pc->pg)) die("postgres sync: %s", PQerrorMessage(pc->pg));
#endif
  for (int i = 0; i < j->nres; i++) PQclear(j->res[i]);
  j->nres = 0;
  j->next = fn;
  if (pc->qt - pc->qh > pc->qmask) {
    // grow the FIFO
    unsigned cap = (pc->qmask + 1) * 2;
    job_t **nq = calloc(cap, sizeof(job_t *));
    unsigned n = pc->qt - pc->qh;
    for (unsigned i = 0; i < n; i++) nq[i] = pc->q[(pc->qh + i) & pc->qmask];
    free(pc->q);
    pc->q = nq;
    pc->qh = 0;
    pc->qt = n;
    pc->qmask = cap - 1;
  }
  pc->q[pc->qt++ & pc->qmask] = j;
  pc->inflight++;
  if (!pc->dirty) {
    pc->dirty = true;
    L->dirty[L->ndirty++] = pc;
  }
}

static void pg_flush(pgc_t *pc) {
  int r = PQflush(pc->pg);
  if (r < 0) die("postgres flush: %s", PQerrorMessage(pc->pg));
  pg_watch(pc, r == 1);
}

// Hand out every result libpq can already parse. This runs after reads and also after every flush:
// libpq reads the socket by itself while a send would block (to avoid a deadlock with the server), and
// results it read that way raise no further epoll event.
static void pg_drain(pgc_t *pc) {
  // Collect finished jobs first and run them after: a job's next step may queue new statements on this
  // connection, and those must not be mixed into the drain below.
  job_t *done = NULL, **tail = &done;
  bool prev_null = false;
  while (pc->qh != pc->qt && !PQisBusy(pc->pg)) {
    PGresult *r = PQgetResult(pc->pg);
    if (!r) {
      if (prev_null) break;  // nothing more is available yet
      prev_null = true;      // end of one statement's results
      continue;
    }
    prev_null = false;
    job_t *j = pc->q[pc->qh & pc->qmask];
    if (PQresultStatus(r) == PGRES_PIPELINE_SYNC) {
      PQclear(r);
      pc->qh++;
      pc->inflight--;
      j->link = NULL;
      *tail = j;
      tail = &j->link;
      continue;
    }
    if (j->nres < MAXRES) j->res[j->nres++] = r;
    else PQclear(r);
  }
  while (done) {
    job_t *j = done;
    done = j->link;
    j->next(j);
  }
}

// End of an event-loop pass: send waiting batched reads, then flush every connection with queued output.
// Running finished jobs can queue more, so repeat until nothing is left.
void pg_flush_dirty(loop_t *L) {
  pgc_t *list[256];
  for (;;) {
    pg_schedule(L);
    int n = L->ndirty;
    if (n == 0) break;
    if (n > 256) n = 256;
    for (int i = 0; i < n; i++) {
      list[i] = L->dirty[L->ndirty - n + i];
      list[i]->dirty = false;
    }
    L->ndirty -= n;
    for (int i = 0; i < n; i++) {
      pg_flush(list[i]);
      pg_drain(list[i]);
    }
  }
}

void pg_event(pgc_t *pc, uint32_t ev) {
  if (ev & (EPOLLIN | EPOLLHUP | EPOLLERR)) {
    if (!PQconsumeInput(pc->pg)) die("postgres connection lost: %s", PQerrorMessage(pc->pg));
  }
  if (pc->wantw || (ev & EPOLLOUT)) pg_flush(pc);
  pg_drain(pc);
}

// ---- batched reads ----
//
// Reads of one kind wait in the loop's queue for that kind. A kind goes out as one statement once its
// oldest request has waited read_window_us (or batch_max requests are waiting) and a read connection has
// fewer than pg_depth statements in flight: the per-request query is the inner side of a LATERAL join over
// the unnested parameters of every waiting request, and each row carries its request's ordinal.
// Postgres pays a fixed cost per statement, so the window keeps batches large at any load, for a few tens
// of ms of latency. (Without it, batches only grow when the connections are busy: at moderate load nearly every
// request went out alone, at ~25% more Postgres CPU per request.)

// The tag list doesn't depend on the viewer: every request waiting when the statement goes out shares one
// execution and gets its row. The result is never kept for later requests. (SHARE_READS=0: one row each.)
int share_reads = 1;
int read_window_us = 40000;

static int64_t now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

struct batch {
  job_t hdr;  // sits in the connection's FIFO like a job; hdr.res[0] is the shared result
  int n;
  bool shared;
  int refs;
  job_t *m[];
};

void pg_read(job_t *j, int kind, job_fn fn) {
  loop_t *L = j->L;
  j->next = fn;
  j->link = NULL;
  j->seq = L->seq++;
  j->t_us = now_us();
  L->bq_cnt[kind]++;
  if (L->bq_tail[kind]) L->bq_tail[kind]->link = j;
  else L->bq_head[kind] = j;
  L->bq_tail[kind] = j;
  L->bq_n++;
}

void batch_release(struct batch *b) {
  if (--b->refs == 0) {
    for (int i = 0; i < b->hdr.nres; i++) PQclear(b->hdr.res[i]);
    free(b);
  }
}

static void batch_done(job_t *h) {
  struct batch *b = (struct batch *)h;
  PGresult *R = h->nres ? h->res[0] : NULL;
  b->refs = b->n + 1;
  bool ok = R && PQresultStatus(R) == PGRES_TUPLES_OK;
  if (!ok) fprintf(stderr, "postgres error (batch): %s", R ? PQresultErrorMessage(R) : "no result\n");
  for (int k = 0; k < b->n; k++) {
    b->m[k]->r0 = -1;
    b->m[k]->rn = 0;
  }
  if (ok && b->shared) {
    if (PQntuples(R) != 1) ok = false;
    for (int k = 0; k < b->n; k++) {
      b->m[k]->r0 = 0;
      b->m[k]->rn = 1;
    }
  } else if (ok) {
    // Each request's rows must come back together and in its own query's order (the nested loop over
    // the unnested parameters guarantees it). If not, fail the batch rather than mix up rows.
    int nt = PQntuples(R);
    for (int r = 0; r < nt && ok; r++) {
      uint64_t v;
      memcpy(&v, PQgetvalue(R, r, 0), 8);
      long idx = (long)__builtin_bswap64(v) - 1;
      job_t *m = idx >= 0 && idx < b->n ? b->m[idx] : NULL;
      if (!m || (m->r0 >= 0 && m->r0 + m->rn != r)) {
        fprintf(stderr, "batch: unexpected row order, failing %d requests\n", b->n);
        ok = false;
        break;
      }
      if (m->r0 < 0) m->r0 = r;
      m->rn++;
    }
  }
  for (int k = 0; k < b->n; k++) {
    job_t *m = b->m[k];
    m->bat = b;
    m->R = ok ? R : NULL;
    if (m->r0 < 0) m->r0 = 0;
    m->next(m);
  }
  batch_release(b);
}

static void put_elem(buf_t *a, const char *s, char type) {
  if (type == 'i') {
    buf_put(a, s, strlen(s));
    return;
  }
  buf_putc(a, '"');
  for (; *s; s++) {
    if (*s == '"' || *s == '\\') buf_putc(a, '\\');
    buf_putc(a, *s);
  }
  buf_putc(a, '"');
}

static void send_batch(loop_t *L, int kind, int pgi) {
  const bkind_t *K = &BKINDS[kind];
  int np = (int)strlen(K->types);
  int n = 0;
  for (job_t *j = L->bq_head[kind]; j && n < batch_max; j = j->link) n++;
  struct batch *b = calloc(1, sizeof *b + n * sizeof(job_t *));
  b->hdr.L = L;
  b->n = n;
  job_t *j = L->bq_head[kind];
  for (int k = 0; k < n; k++) {
    b->m[k] = j;
    j = j->link;
  }
  L->bq_head[kind] = j;
  if (!j) L->bq_tail[kind] = NULL;
  L->bq_n -= n;
  L->bq_cnt[kind] -= n;

  // parameters: one array literal per column, or the count
  static __thread buf_t pb[4];
  const char *vals[4];
  char cnt[24];
  if (np == 0) {
    snprintf(cnt, sizeof cnt, "%d", n);
    vals[0] = cnt;
  }
  for (int p = 0; p < np; p++) {
    buf_t *a = &pb[p];
    a->len = 0;
    buf_putc(a, '{');
    for (int k = 0; k < n; k++) {
      if (k) buf_putc(a, ',');
      put_elem(a, b->m[k]->bv[p], K->types[p]);
    }
    buf_putc(a, '}');
    buf_putc(a, 0);
    vals[p] = a->p;
  }
  if (L->id == 0) {
    dbg_batches++;
    dbg_batched += n;
  }
  b->hdr.pgi = pgi;
  if (share_reads && K->shared_stmt > 0) {
    b->shared = true;
    pg_q(&b->hdr, K->shared_stmt, NULL, NULL);
    pg_end(&b->hdr, batch_done);
    return;
  }
  pg_q(&b->hdr, K->stmt, vals, NULL);
  pg_end(&b->hdr, batch_done);
}

// Send the kinds whose window is over while a read connection has room; L->next_due is when the next
// window ends (the loop sleeps until then at most).
void pg_schedule(loop_t *L) {
  L->next_due = 0;
  if (L->bq_n == 0) return;
  int64_t now = now_us();
  while (L->bq_n > 0) {
    int best = 0, load = L->pg[0].inflight;
    for (int i = 1; i < L->npg; i++)
      if (L->pg[i].inflight < load) {
        load = L->pg[i].inflight;
        best = i;
      }
    if (load >= pg_depth) return;  // a connection's result runs this again
    int kind = -1;
    int64_t due_min = INT64_MAX;
    for (int k = 0; k < NBK; k++) {
      job_t *h = L->bq_head[k];
      if (!h) continue;
      int64_t due = h->t_us + read_window_us;
      if (due > now && L->bq_cnt[k] < batch_max) {
        if (due < due_min) due_min = due;
        continue;
      }
      if (kind < 0 || h->seq < L->bq_head[kind]->seq) kind = k;
    }
    if (kind < 0) {
      L->next_due = due_min;
      return;
    }
    send_batch(L, kind, best);
  }
}

int64_t pg_wait_us(loop_t *L) {
  if (!L->next_due) return -1;
  int64_t d = L->next_due - now_us();
  return d > 0 ? d : 0;
}
