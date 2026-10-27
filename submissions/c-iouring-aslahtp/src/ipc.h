/* Shared-memory message rings between the workers and the drain process (one pair per worker), mapped before
 * fork. Each ring has exactly one producer and one consumer, so positions are plain atomics: the producer
 * publishes with a release store of tail, the consumer frees space with a release store of head.
 *
 * A message is a 16-byte-aligned record: struct ipc_hdr, then len payload bytes. A record that would cross the
 * end of the ring is preceded by a wrap marker and starts again at offset 0. */
#pragma once
#include <stdatomic.h>

#include "common.h"

struct ring {
    _Alignas(64) _Atomic uint64_t head;  /* consumer position (bytes, ever increasing), published */
    uint64_t cpos;                       /* consumer only: end of the last record peeked */
    _Alignas(64) _Atomic uint64_t tail;  /* producer position, published */
    uint64_t ppos;                       /* producer only: end of the open reservation */
    _Alignas(64) uint64_t size;          /* data bytes, a power of two */
    char data[];
};

struct ipc_hdr {
    uint32_t kind;
    uint32_t len;     /* payload bytes after this header */
    uint64_t token;   /* the worker's id for the request (opaque to the drain) */
};

/* Message kinds. */
enum {
    IPC_WRAP = 0xffffffff,
    IPC_PG = 1,       /* worker -> drain: a read unit (Bind/Execute pairs and Sync) to run as is;
                       * drain -> worker: the backend's reply to it, through ReadyForQuery */
    IPC_PLAN = 2,     /* worker -> drain: a planned read (struct plan_req); drain -> worker: status + JSON */
};

/* Space for one record of len payload bytes, or NULL if the ring is too full (try again later).
 * Fill it, then ipc_commit. Only one reservation may be open at a time. */
void *ipc_reserve(struct ring *r, uint32_t kind, uint32_t len, uint64_t token);
void ipc_commit(struct ring *r);

/* The next record, or NULL. ipc_release frees it (and everything read before it). */
const struct ipc_hdr *ipc_peek(struct ring *r);
void ipc_release(struct ring *r);

#define IPC_REC(len) ((sizeof(struct ipc_hdr) + (size_t)(len) + 15) & ~(size_t)15)

/* Everything the processes share, created by main before forking. */
struct shared {
    int nworkers;
    int drain_efd;          /* workers -> drain wake-ups */
    int *worker_efd;        /* drain (and bcrypt threads) -> worker wake-ups */
    struct ring **to_drain;
    struct ring **to_worker;
};
extern struct shared ipc;

void ipc_setup(int nworkers, size_t ring_bytes);
void ipc_wake(int efd);
