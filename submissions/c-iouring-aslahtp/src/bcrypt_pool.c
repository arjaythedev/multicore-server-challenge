/* bcrypt runs on its own threads so a hash never stalls the event loop. Jobs go in through a mutex-guarded queue;
 * finished jobs come back on a list, with an eventfd write that wakes the loop's pending read.
 *
 * A hasher runs up to BCRYPT_BATCH jobs at once through the interleaved kernel (bcrypt_lanes.c: 4 lanes cost about
 * 1.4 times one hash, so each hash about a third). When fewer are queued it waits up to bcrypt_wait_ms for more:
 * logins and sign-ups are under 0.1% of requests, so their latency does not move the percentiles, while the CPU
 * saved is shared by everything else. Hashers run niced, so Postgres and the event loops win a contended core, and
 * a job that waited over BCRYPT_STALE_US is answered 503 instead of hashed: by then its client is about to give
 * up, and hashing it would only delay the jobs behind it. */
#include <errno.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include "pg_conn.h"
#include "worker.h"

#define BCRYPT_COST 10
#define BCRYPT_BATCH 8               /* most jobs one run can take (cfg.bcrypt_batch picks, default 4) */
#define BCRYPT_FULL 4                /* a batch this big starts without waiting */
#define BCRYPT_STALE_US 8000000

struct bcrypt_pool {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    struct req *head, *tail;
    int queued;
    pthread_mutex_t done_mu;
    struct req *done;
    int efd;
};

static int64_t mono_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/* Hashes a batch: the jobs of the common cost (10) together, any other cost (a stored hash from elsewhere) alone. */
static void run_batch(struct req **jobs, int n) {
    struct bcrypt_lane in[BCRYPT_BATCH];
    uint8_t out[BCRYPT_BATCH][BCRYPT_RAW];
    uint8_t salts[BCRYPT_BATCH][BCRYPT_SALT];
    struct bcrypt_setting set[BCRYPT_BATCH];
    struct req *lane_job[BCRYPT_BATCH];
    int lanes = 0;
    int64_t now = mono_us();
    for (int i = 0; i < n; i++) {
        struct bc_job *j = &jobs[i]->bc;
        j->ok = false;
        if (now - j->t_us > BCRYPT_STALE_US) {
            j->stale = true;
            continue;
        }
        const uint8_t *salt;
        if (j->kind == BC_VERIFY) {
            if (!bcrypt_parse(j->hash, strlen(j->hash), &set[i])) continue;
            if (set[i].cost != BCRYPT_COST) {
                j->ok = bcrypt_verify(j->pw, j->pwlen, j->hash, strlen(j->hash));
                continue;
            }
            salt = set[i].salt;
        } else {
            random_bytes(salts[i], BCRYPT_SALT);
            salt = salts[i];
        }
        in[lanes] = (struct bcrypt_lane){j->pw, j->pwlen, salt};
        lane_job[lanes++] = jobs[i];
    }
    bcrypt_raw_lanes(in, lanes, BCRYPT_COST, out);
    for (int k = 0; k < lanes; k++) {
        struct bc_job *j = &lane_job[k]->bc;
        if (j->kind == BC_VERIFY) {
            char enc[32];
            bcrypt_b64_encode(enc, out[k], BCRYPT_RAW);
            j->ok = ct_equal(enc, j->hash + BCRYPT_LEN - 31, 31);
        } else {
            memcpy(j->hash, "$2a$10$", 7);
            bcrypt_b64_encode(j->hash + 7, in[k].salt, BCRYPT_SALT);
            bcrypt_b64_encode(j->hash + 29, out[k], BCRYPT_RAW);
            j->hash[BCRYPT_LEN] = 0;
            j->ok = true;
        }
    }
}

static void *hasher(void *arg) {
    struct bcrypt_pool *bp = arg;
    setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), cfg.bcrypt_nice);
    struct req *jobs[BCRYPT_BATCH];
    for (;;) {
        pthread_mutex_lock(&bp->mu);
        while (!bp->head) pthread_cond_wait(&bp->cv, &bp->mu);
        /* Wait for company until the oldest job has waited bcrypt_wait_ms. */
        int64_t deadline = bp->head->bc.t_us + (int64_t)cfg.bcrypt_wait_ms * 1000;
        int full = cfg.bcrypt_batch < BCRYPT_FULL ? cfg.bcrypt_batch : BCRYPT_FULL;
        while (bp->queued < full) {
            int64_t left = deadline - mono_us();
            if (left <= 0) break;
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            int64_t ns = ts.tv_nsec + left % 1000000 * 1000;
            ts.tv_sec += left / 1000000 + ns / 1000000000;
            ts.tv_nsec = ns % 1000000000;
            pthread_cond_timedwait(&bp->cv, &bp->mu, &ts);
        }
        int n = 0;
        while (bp->head && n < cfg.bcrypt_batch) {
            jobs[n++] = bp->head;
            bp->head = bp->head->next;
        }
        if (!bp->head) bp->tail = NULL;
        bp->queued -= n;
        pthread_mutex_unlock(&bp->mu);

        run_batch(jobs, n);

        pthread_mutex_lock(&bp->done_mu);
        for (int i = 0; i < n; i++) {
            jobs[i]->next = bp->done;
            bp->done = jobs[i];
        }
        pthread_mutex_unlock(&bp->done_mu);
        uint64_t one = 1;
        while (write(bp->efd, &one, sizeof one) < 0 && errno == EINTR) {}
    }
    return NULL;
}

struct bcrypt_pool *bcrypt_pool_start(struct worker *w, int threads) {
    struct bcrypt_pool *bp = xcalloc(1, sizeof *bp);
    pthread_mutex_init(&bp->mu, NULL);
    pthread_cond_init(&bp->cv, NULL);
    pthread_mutex_init(&bp->done_mu, NULL);
    bp->efd = w->efd;
    for (int i = 0; i < threads; i++) {
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 1024 * 1024);  /* the kernel keeps 8 lanes of Blowfish state (33 KB) */
        if (pthread_create(&t, &attr, hasher, bp) != 0) die("pthread_create failed");
        pthread_attr_destroy(&attr);
        pthread_detach(t);
    }
    return bp;
}

void bcrypt_pool_push(struct bcrypt_pool *bp, struct req *r) {
    r->next = NULL;
    r->bc.stale = false;
    r->bc.t_us = mono_us();
    pthread_mutex_lock(&bp->mu);
    if (bp->tail) bp->tail->next = r;
    else bp->head = r;
    bp->tail = r;
    bp->queued++;
    pthread_cond_signal(&bp->cv);
    pthread_mutex_unlock(&bp->mu);
}

/* All finished jobs, as a list linked through next (most recent first). */
struct req *bcrypt_pool_take_done(struct bcrypt_pool *bp) {
    pthread_mutex_lock(&bp->done_mu);
    struct req *r = bp->done;
    bp->done = NULL;
    pthread_mutex_unlock(&bp->done_mu);
    return r;
}
