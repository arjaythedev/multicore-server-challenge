// bcrypt with cost 10, five hashes at a time. The reactors hand jobs to a small pool of low-priority
// threads and collect finished ones each pass, so a login never blocks an event loop.
#ifndef BCRYPT_H
#define BCRYPT_H
#include <stddef.h>
#include <stdint.h>

typedef struct bc_job {
    struct bc_job *next;
    void *context;       // the reactor's, untouched here
    int owner;           // which reactor collects it
    int verify;          // 1: compare with `hash`, 0: make a new `hash`
    int matched;         // verify's result
    int password_len;    // at most 72 bytes are used
    uint8_t password[73];
    char hash[61];       // "$2a$10$..." (NUL-terminated)
} bc_job;

// Starts `threads` hashing threads for `owners` reactors.
void bc_start(int threads, int owners);
bc_job *bc_new(void);
void bc_free(bc_job *job);
void bc_submit(bc_job *job);
// The finished jobs of one reactor as a list, or NULL. Cheap when there are none.
bc_job *bc_collect(int owner);
// One verify on the calling thread. Exposed for the self test.
int bc_check(const uint8_t *password, int len, const char *hash);
#endif
