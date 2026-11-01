#include "crypto/offload.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "config.h"
#include "core/wake.h"
#include "util.h"

struct job {
    crypto_work_fn work;
    crypto_resume_fn resume;
    void *arg;
    int worker;
    struct job *next;
};

struct mailbox {
    pthread_mutex_t mu;
    struct job *head;
    struct job *tail;
    int wake_fd;
    bool bound;
};

static struct {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    struct job *head;
    struct job *tail;
} queue;

static pthread_t *threads;
static int thread_count;

static struct mailbox *mailboxes;
static int mailbox_count;

static void *pool_main(void *unused) {
    (void)unused;
    for (;;) {
        pthread_mutex_lock(&queue.mu);
        while (!queue.head) pthread_cond_wait(&queue.cv, &queue.mu);
        struct job *job = queue.head;
        queue.head = job->next;
        if (!queue.head) queue.tail = NULL;
        pthread_mutex_unlock(&queue.mu);

        job->work(job->arg);

        struct mailbox *mailbox = &mailboxes[job->worker];
        pthread_mutex_lock(&mailbox->mu);
        job->next = NULL;
        if (mailbox->tail) mailbox->tail->next = job;
        else mailbox->head = job;
        mailbox->tail = job;
        pthread_mutex_unlock(&mailbox->mu);
        wake_fire(mailbox->wake_fd);
    }
    return NULL;
}

static void mailbox_ready(void *user, loop_fd *self, unsigned events) {
    (void)self;
    if (!(events & LOOP_IN)) return;
    struct mailbox *mailbox = user;

    wake_drain(mailbox->wake_fd);

    pthread_mutex_lock(&mailbox->mu);
    struct job *list = mailbox->head;
    mailbox->head = mailbox->tail = NULL;
    pthread_mutex_unlock(&mailbox->mu);

    while (list) {
        struct job *job = list;
        list = list->next;
        job->resume(job->arg);
        free(job);
    }
}

void crypto_init(int threads_count, int workers) {
    CHECK(threads_count >= CRYPTO_THREADS_MIN, "crypto: too few threads");
    CHECK(workers >= 1, "crypto: no workers");
    thread_count = threads_count;
    mailbox_count = workers;

    pthread_mutex_init(&queue.mu, NULL);
    pthread_cond_init(&queue.cv, NULL);
    queue.head = queue.tail = NULL;

    mailboxes = xcalloc((size_t)workers, sizeof *mailboxes);
    for (int i = 0; i < workers; i++) {
        pthread_mutex_init(&mailboxes[i].mu, NULL);
        mailboxes[i].wake_fd = wake_new();
        CHECK(mailboxes[i].wake_fd >= 0, "crypto: eventfd creation failed");
    }

    threads = xmalloc((size_t)thread_count * sizeof *threads);
    for (int i = 0; i < thread_count; i++)
        CHECK(pthread_create(&threads[i], NULL, pool_main, NULL) == 0,
              "crypto: pthread_create failed");
}

void crypto_bind(int worker_id, loop *l) {
    CHECK(worker_id >= 0 && worker_id < mailbox_count, "crypto_bind: worker id");
    struct mailbox *mailbox = &mailboxes[worker_id];
    CHECK(!mailbox->bound, "crypto_bind: worker %d already bound", worker_id);
    CHECK(loop_add(l, mailbox->wake_fd, LOOP_IN, mailbox_ready, mailbox) != NULL,
          "crypto_bind: loop_add failed");
    mailbox->bound = true;
}

void crypto_submit(int worker_id, crypto_work_fn work, crypto_resume_fn resume,
                   void *arg) {
    CHECK(worker_id >= 0 && worker_id < mailbox_count, "crypto_submit: worker id");
    CHECK(work != NULL && resume != NULL, "crypto_submit: callbacks required");

    struct job *job = xmalloc(sizeof *job);
    job->work = work;
    job->resume = resume;
    job->arg = arg;
    job->worker = worker_id;
    job->next = NULL;

    pthread_mutex_lock(&queue.mu);
    if (queue.tail) queue.tail->next = job;
    else queue.head = job;
    queue.tail = job;
    pthread_mutex_unlock(&queue.mu);
    pthread_cond_signal(&queue.cv);
}

/* no pool work: park `arg` straight on the worker's mailbox so `resume` runs on
 * the worker's loop (thread hop only) */
void crypto_post(int worker_id, crypto_resume_fn resume, void *arg) {
    CHECK(worker_id >= 0 && worker_id < mailbox_count, "crypto_post: worker id");
    CHECK(resume != NULL, "crypto_post: resume required");

    struct job *job = xmalloc(sizeof *job);
    job->work = NULL;
    job->resume = resume;
    job->arg = arg;
    job->worker = worker_id;
    job->next = NULL;

    struct mailbox *mailbox = &mailboxes[worker_id];
    pthread_mutex_lock(&mailbox->mu);
    if (mailbox->tail) mailbox->tail->next = job;
    else mailbox->head = job;
    mailbox->tail = job;
    pthread_mutex_unlock(&mailbox->mu);
    wake_fire(mailbox->wake_fd);
}
