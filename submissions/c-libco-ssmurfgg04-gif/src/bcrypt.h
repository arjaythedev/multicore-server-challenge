/* bcrypt.h - lane-interleaved bcrypt (cost 10) with libxcrypt fallback */
#pragma once
#include <stddef.h>
#include <stdint.h>

#define BCRYPT_HASHLEN 60          /* $2a$10$<22 salt><31 hash> */
#define BCRYPT_PWMAX 128

typedef struct bcrypt_job bcrypt_job_t;

struct bcrypt_job {
    int mode;                      /* BCRYPT_HASH or BCRYPT_VERIFY */
#define BCRYPT_HASH 0
#define BCRYPT_VERIFY 1
    char pw[BCRYPT_PWMAX];         /* raw password bytes */
    size_t pwlen;
    char hash[BCRYPT_HASHLEN + 1]; /* VERIFY: stored hash in. HASH: result out */
    uint8_t saltbin[16];           /* HASH: salt to use (random for new hashes) */
    int verified;                  /* VERIFY result: 1 match, 0 no */
    int cost;
    int fallback;                  /* run via libxcrypt (non-ASCII / >72 bytes) */
    void (*done)(bcrypt_job_t *j); /* runs on the requesting worker's loop thread */
    void *req;                     /* opaque back-pointer (req_t *) */
    struct bcrypt_job *next;       /* worker done-list link */
};

/* Parse a stored hash: version prefix $2a/$2b/$2y, cost, 22-char salt.
 * Returns 0 and fills cost+salt, or -1 if malformed (verify can 401). */
int bcrypt_parse_hash(const char *hash, int *cost, uint8_t salt[16]);

/* Queue a job. Thread-safe; completion via j->done on the loop thread.
 * All submitted jobs must share j->cost to be batched into one run. */
void bcrypt_submit(bcrypt_job_t *j);

/* Verify the implementation against libxcrypt on fixed vectors + random
 * inputs (cheap cost). Returns 0 on success, nonzero on mismatch. */
int bcrypt_selftest(void);

/* Start the worker threads. */
void bcrypt_pool_start(int threads);

/* Core: run `n` jobs of one cost step-locked for ILP (n <= 4). */
void bcrypt_run_jobs(bcrypt_job_t **jobs, int n);
