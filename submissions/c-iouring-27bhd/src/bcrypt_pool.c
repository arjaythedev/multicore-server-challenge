#define _GNU_SOURCE
#include "bcrypt_pool.h"
#include "auth_crypto.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sched.h>

bcrypt_pool_t g_bcrypt_pool;

static void *bcrypt_worker_thread(void *arg) {
    struct sched_param sp;
    sp.sched_priority = 0;
    sched_setscheduler(0, SCHED_BATCH, &sp);

    while (1) {
        pthread_mutex_lock(&g_bcrypt_pool.queue_mutex);
        while (g_bcrypt_pool.running && !g_bcrypt_pool.head) {
            pthread_cond_wait(&g_bcrypt_pool.queue_cond, &g_bcrypt_pool.queue_mutex);
        }
        if (!g_bcrypt_pool.running && !g_bcrypt_pool.head) {
            pthread_mutex_unlock(&g_bcrypt_pool.queue_mutex);
            break;
        }

        bcrypt_task_t *task = g_bcrypt_pool.head;
        g_bcrypt_pool.head = task->next;
        if (!g_bcrypt_pool.head) {
            g_bcrypt_pool.tail = NULL;
        }
        pthread_mutex_unlock(&g_bcrypt_pool.queue_mutex);

        // Execute computation
        if (task->op == BCRYPT_OP_VERIFY) {
            task->success = verify_password(task->password, task->stored_hash);
        } else if (task->op == BCRYPT_OP_HASH) {
            task->success = hash_password(task->password, task->out_hash, sizeof(task->out_hash));
        }

        // Append to originating worker's completed queue
        int wid = task->worker_id;
        task->next = NULL;
        pthread_mutex_lock(&g_bcrypt_pool.comp_mutex[wid]);
        if (!g_bcrypt_pool.comp_tail[wid]) {
            g_bcrypt_pool.comp_head[wid] = task;
            g_bcrypt_pool.comp_tail[wid] = task;
        } else {
            g_bcrypt_pool.comp_tail[wid]->next = task;
            g_bcrypt_pool.comp_tail[wid] = task;
        }
        pthread_mutex_unlock(&g_bcrypt_pool.comp_mutex[wid]);

        // Notify originating worker thread via its eventfd
        int efd = g_bcrypt_pool.worker_efds[wid];
        if (efd >= 0) {
            uint64_t one = 1;
            ssize_t wret = write(efd, &one, sizeof(one));
            (void)wret;
        }
    }
    return NULL;
}

void bcrypt_pool_init(int num_threads) {
    pthread_mutex_init(&g_bcrypt_pool.queue_mutex, NULL);
    pthread_cond_init(&g_bcrypt_pool.queue_cond, NULL);
    g_bcrypt_pool.head = NULL;
    g_bcrypt_pool.tail = NULL;
    g_bcrypt_pool.running = true;
    for (int i = 0; i < 32; i++) {
        g_bcrypt_pool.worker_efds[i] = -1;
        pthread_mutex_init(&g_bcrypt_pool.comp_mutex[i], NULL);
        g_bcrypt_pool.comp_head[i] = NULL;
        g_bcrypt_pool.comp_tail[i] = NULL;
    }

    if (num_threads <= 0 || num_threads > 4) num_threads = 4;
    for (int i = 0; i < num_threads; i++) {
        pthread_create(&g_bcrypt_pool.threads[i], NULL, bcrypt_worker_thread, NULL);
    }
}

void bcrypt_pool_register_worker_efd(int worker_id, int efd) {
    if (worker_id >= 0 && worker_id < 32) {
        g_bcrypt_pool.worker_efds[worker_id] = efd;
    }
}

void bcrypt_pool_enqueue(bcrypt_task_t *task) {
    task->next = NULL;
    pthread_mutex_lock(&g_bcrypt_pool.queue_mutex);
    if (!g_bcrypt_pool.tail) {
        g_bcrypt_pool.head = task;
        g_bcrypt_pool.tail = task;
    } else {
        g_bcrypt_pool.tail->next = task;
        g_bcrypt_pool.tail = task;
    }
    pthread_cond_signal(&g_bcrypt_pool.queue_cond);
    pthread_mutex_unlock(&g_bcrypt_pool.queue_mutex);
}

bcrypt_task_t *bcrypt_pool_pop_completed(int worker_id) {
    if (worker_id < 0 || worker_id >= 32) return NULL;
    pthread_mutex_lock(&g_bcrypt_pool.comp_mutex[worker_id]);
    bcrypt_task_t *tasks = g_bcrypt_pool.comp_head[worker_id];
    g_bcrypt_pool.comp_head[worker_id] = NULL;
    g_bcrypt_pool.comp_tail[worker_id] = NULL;
    pthread_mutex_unlock(&g_bcrypt_pool.comp_mutex[worker_id]);
    return tasks;
}

