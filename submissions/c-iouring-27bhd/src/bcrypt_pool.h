#ifndef BCRYPT_POOL_H
#define BCRYPT_POOL_H

#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>

typedef struct bcrypt_task {
    enum { BCRYPT_OP_HASH, BCRYPT_OP_VERIFY } op;
    int client_fd;
    int worker_id;
    char password[128];
    char stored_hash[128];

    // User data passed along for login / register completion
    int64_t user_id;
    char email[128];
    char username[128];
    char bio[1024];
    char image[1024];
    bool has_bio;
    bool has_image;

    // Result
    bool success;
    char out_hash[128];

    struct bcrypt_task *next;
} bcrypt_task_t;

typedef struct {
    pthread_t threads[4];
    pthread_mutex_t queue_mutex;
    pthread_cond_t queue_cond;
    bcrypt_task_t *head;
    bcrypt_task_t *tail;
    bool running;
    int worker_efds[32];

    pthread_mutex_t comp_mutex[32];
    bcrypt_task_t *comp_head[32];
    bcrypt_task_t *comp_tail[32];
} bcrypt_pool_t;

extern bcrypt_pool_t g_bcrypt_pool;

void bcrypt_pool_init(int num_threads);
void bcrypt_pool_register_worker_efd(int worker_id, int efd);
void bcrypt_pool_enqueue(bcrypt_task_t *task);
bcrypt_task_t *bcrypt_pool_pop_completed(int worker_id);

#endif // BCRYPT_POOL_H
