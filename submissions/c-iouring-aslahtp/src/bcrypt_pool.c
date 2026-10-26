/* bcrypt runs on its own threads so a ~50 ms hash never stalls the event loop. Jobs go in through a mutex-guarded
 * queue; finished jobs come back on a list, with an eventfd write that wakes the loop's pending read.
 *
 * M8 replaces the single-lane hash with interleaved lanes, SCHED_IDLE hashers and a watchdog. */
#include <errno.h>
#include <pthread.h>
#include <unistd.h>

#include "pg_conn.h"
#include "worker.h"

#define BCRYPT_COST 10

struct bcrypt_pool {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    struct req *head, *tail;
    pthread_mutex_t done_mu;
    struct req *done;
    int efd;
};

static void run_job(struct bc_job *j) {
    if (j->kind == BC_VERIFY) {
        j->ok = bcrypt_verify(j->pw, j->pwlen, j->hash, strlen(j->hash));
    } else {
        uint8_t salt[BCRYPT_SALT];
        random_bytes(salt, sizeof salt);
        bcrypt_hash(j->pw, j->pwlen, BCRYPT_COST, salt, j->hash);
        j->ok = true;
    }
}

static void *hasher(void *arg) {
    struct bcrypt_pool *bp = arg;
    for (;;) {
        pthread_mutex_lock(&bp->mu);
        while (!bp->head) pthread_cond_wait(&bp->cv, &bp->mu);
        struct req *r = bp->head;
        bp->head = r->next;
        if (!bp->head) bp->tail = NULL;
        pthread_mutex_unlock(&bp->mu);

        run_job(&r->bc);

        pthread_mutex_lock(&bp->done_mu);
        r->next = bp->done;
        bp->done = r;
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
        pthread_attr_setstacksize(&attr, 256 * 1024);
        if (pthread_create(&t, &attr, hasher, bp) != 0) die("pthread_create failed");
        pthread_attr_destroy(&attr);
        pthread_detach(t);
    }
    return bp;
}

void bcrypt_pool_push(struct bcrypt_pool *bp, struct req *r) {
    r->next = NULL;
    pthread_mutex_lock(&bp->mu);
    if (bp->tail) bp->tail->next = r;
    else bp->head = r;
    bp->tail = r;
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
