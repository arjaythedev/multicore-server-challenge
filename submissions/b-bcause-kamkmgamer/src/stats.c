// Optional per-second diagnostics, enabled with STATS=1 (off by default: every hook is one predictable branch
// on STATS_ON). Each worker prints one line per second to stderr: requests, event-loop CPU, server-side latency
// percentiles (whole request, Postgres batches split into reads / reads queued behind a write on the same
// connection / writes, bcrypt jobs), and how many batches sit in each Postgres connection's pipeline.
#include "conduit.h"
#include <time.h>

bool STATS_ON;

#define HB 128
typedef struct { uint64_t n; uint32_t b[HB]; } hist_t;

struct stats {
    uint64_t last_us, last_cpu_us;
    int64_t conns; // open client connections (carried across seconds)
    uint64_t reqs, busy_us, wakes, cqes, maxcqe, maxbusy_us;
    uint64_t enq, enq_depth_sum, maxdepth, maxwq;
    hist_t total, pg_r, pg_rb, pg_w, bc;
};

uint64_t stats_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}

static uint64_t cpu_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return (uint64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}

static inline int hb(uint64_t us) {
    if (us < 4) return (int)us;
    int e = 63 - __builtin_clzll(us);
    int i = e * 4 + (int)((us >> (e - 2)) & 3) - 4;
    return i < HB ? i : HB - 1;
}

static inline uint64_t hb_val(int i) {
    if (i < 4) return (uint64_t)i;
    int e = (i + 4) >> 2, s = (i + 4) & 3;
    return (uint64_t)(4 + s) << (e - 2);
}

static inline void hadd(hist_t *h, uint64_t us) {
    h->n++;
    h->b[hb(us)]++;
}

static double hpct(const hist_t *h, double q) {
    if (!h->n) return 0;
    uint64_t want = (uint64_t)(q * h->n), seen = 0;
    if (want >= h->n) want = h->n - 1;
    for (int i = 0; i < HB; i++) {
        seen += h->b[i];
        if (seen > want) return hb_val(i) / 1000.0;
    }
    return 0;
}

void stats_init(worker_t *w) {
    w->stats = calloc(1, sizeof *w->stats);
    if (!w->stats) die("out of memory");
    w->stats->last_us = stats_now();
    w->stats->last_cpu_us = cpu_now();
}

void stats_req_done(worker_t *w, uint64_t t0) {
    w->stats->reqs++;
    hadd(&w->stats->total, stats_now() - t0);
}

void stats_pg_enq(pgconn_t *c, pgbatch_t *b) {
    stats_t *s = c->w->stats;
    b->behind_w = c->pend_w > 0;
    if (b->is_write) c->pend_w++;
    s->enq++;
    s->enq_depth_sum += c->inflight; // already counts this batch
    if ((uint64_t)c->inflight > s->maxdepth) s->maxdepth = c->inflight;
}

void stats_pg_done(pgconn_t *c, pgbatch_t *b) {
    stats_t *s = c->w->stats;
    uint64_t us = stats_now() - b->t_enq;
    c->lat_sum += us;
    c->lat_n++;
    if (b->is_write) {
        c->pend_w--;
        hadd(&s->pg_w, us);
    } else {
        hadd(b->behind_w ? &s->pg_rb : &s->pg_r, us);
    }
}

void stats_bc_done(worker_t *w, uint64_t t0) { hadd(&w->stats->bc, stats_now() - t0); }

bool stmt_is_write(int stmt) {
    static signed char cache[256];
    if (!cache[stmt]) {
        const char *q = STMTS[stmt].sql;
        cache[stmt] = strstr(q, "INSERT") || strstr(q, "UPDATE") || strstr(q, "DELETE") ? 2 : 1;
    }
    return cache[stmt] == 2;
}

// Called once per event-loop wake-up: t0 is when the wait returned, n the completions handled.
void stats_loop(worker_t *w, uint64_t t0, unsigned n) {
    stats_t *s = w->stats;
    uint64_t now = stats_now();
    s->wakes++;
    s->cqes += n;
    if (n > s->maxcqe) s->maxcqe = n;
    s->busy_us += now - t0;
    if ((uint64_t)w->wq_n > s->maxwq) s->maxwq = w->wq_n;
    if (now - t0 > s->maxbusy_us) s->maxbusy_us = now - t0;
    if (now - s->last_us < 1000000) return;

    uint64_t cpu = cpu_now();
    double wall = (double)(now - s->last_us);
    int tot = 0, mx = 0;
    char snap[512], lat[512];
    int sl = 0, ll = 0;
    for (int i = 0; i < w->npg; i++) {
        pgconn_t *c = &w->pg[i];
        int k = c->inflight;
        tot += k;
        if (k > mx) mx = k;
        if (sl < (int)sizeof snap - 8) sl += snprintf(snap + sl, sizeof snap - sl, "%d%s", k, i + 1 < w->npg ? "," : "");
        if (ll < (int)sizeof lat - 8)
            ll += snprintf(lat + ll, sizeof lat - ll, "%.0f%s", c->lat_n ? c->lat_sum / 1000.0 / c->lat_n : 0, i + 1 < w->npg ? "," : "");
        c->lat_sum = c->lat_n = 0;
    }
    fprintf(stderr,
            "STATS w%d conns=%ld req=%lu loopcpu=%.0f%% busy=%.0f%% wake=%lu cqe/wake=%.1f maxcqe=%lu maxwake=%.1fms | "
            "tot p50=%.1f p99=%.1f max=%.1f | pgR n=%lu p50=%.1f p99=%.1f | pgR-behind-W n=%lu p50=%.1f p99=%.1f | "
            "pgW n=%lu p50=%.1f p99=%.1f | bc n=%lu p50=%.0f p99=%.0f | inflight sum=%d max=%d enq-avg=%.1f enq-max=%lu wq=%d wq-max=%lu [%s] connlat-ms [%s]\n",
            w->id, (long)s->conns, s->reqs, 100.0 * (cpu - s->last_cpu_us) / wall, 100.0 * s->busy_us / wall, s->wakes,
            s->wakes ? (double)s->cqes / s->wakes : 0, s->maxcqe, s->maxbusy_us / 1000.0,
            hpct(&s->total, .5), hpct(&s->total, .99), hpct(&s->total, 1), s->pg_r.n, hpct(&s->pg_r, .5),
            hpct(&s->pg_r, .99), s->pg_rb.n, hpct(&s->pg_rb, .5), hpct(&s->pg_rb, .99), s->pg_w.n,
            hpct(&s->pg_w, .5), hpct(&s->pg_w, .99), s->bc.n, hpct(&s->bc, .5), hpct(&s->bc, .99), tot, mx,
            s->enq ? (double)s->enq_depth_sum / s->enq : 0, s->maxdepth, w->wq_n, s->maxwq, snap, lat);
    uint64_t keep_last_cpu = cpu;
    int64_t conns = s->conns;
    memset(s, 0, sizeof *s);
    s->conns = conns;
    s->last_us = now;
    s->last_cpu_us = keep_last_cpu;
}

void stats_conn(worker_t *w, int d) { w->stats->conns += d; }
