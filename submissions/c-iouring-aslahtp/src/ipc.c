#include "ipc.h"

#include <errno.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <unistd.h>

struct shared ipc;

void *ipc_reserve(struct ring *r, uint32_t kind, uint32_t len, uint64_t token) {
    size_t rec = IPC_REC(len);
    uint64_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint64_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    uint64_t off = t & (r->size - 1);
    bool wrap = off + rec > r->size;
    uint64_t need = rec + (wrap ? r->size - off : 0);
    if (rec > r->size / 2) die("ipc message of %u bytes is too large for the ring", len);
    if (r->size - (t - h) < need) return NULL;
    if (wrap) {
        /* Records are 16-byte aligned, so at least a header's worth of space is left before the end. */
        struct ipc_hdr *m = (struct ipc_hdr *)(r->data + off);
        m->kind = IPC_WRAP;
        m->len = 0;
        t += r->size - off;
        off = 0;
    }
    struct ipc_hdr *m = (struct ipc_hdr *)(r->data + off);
    m->kind = kind;
    m->len = len;
    m->token = token;
    r->ppos = t + rec;
    return m + 1;
}

void ipc_commit(struct ring *r) { atomic_store_explicit(&r->tail, r->ppos, memory_order_release); }

const struct ipc_hdr *ipc_peek(struct ring *r) {
    uint64_t p = r->cpos;
    uint64_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    if (p == t) return NULL;
    uint64_t off = p & (r->size - 1);
    const struct ipc_hdr *m = (const struct ipc_hdr *)(r->data + off);
    if (m->kind == IPC_WRAP) {
        p += r->size - off;
        m = (const struct ipc_hdr *)r->data;
    }
    r->cpos = p + IPC_REC(m->len);
    return m;
}

void ipc_release(struct ring *r) { atomic_store_explicit(&r->head, r->cpos, memory_order_release); }

static struct ring *ring_new(size_t bytes) {
    size_t total = sizeof(struct ring) + bytes;
    struct ring *r = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (r == MAP_FAILED) die("mmap ring: %s", strerror(errno));
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
    r->cpos = r->ppos = 0;
    r->size = bytes;
    return r;
}

void ipc_setup(int nworkers, size_t ring_bytes) {
    if (ring_bytes & (ring_bytes - 1)) die("ring size must be a power of two");
    ipc.nworkers = nworkers;
    ipc.drain_efd = eventfd(0, EFD_CLOEXEC);
    if (ipc.drain_efd < 0) die("eventfd: %s", strerror(errno));
    ipc.worker_efd = xcalloc((size_t)nworkers, sizeof(int));
    ipc.to_drain = xcalloc((size_t)nworkers, sizeof(struct ring *));
    ipc.to_worker = xcalloc((size_t)nworkers, sizeof(struct ring *));
    for (int i = 0; i < nworkers; i++) {
        ipc.worker_efd[i] = eventfd(0, EFD_CLOEXEC);
        if (ipc.worker_efd[i] < 0) die("eventfd: %s", strerror(errno));
        ipc.to_drain[i] = ring_new(ring_bytes);
        ipc.to_worker[i] = ring_new(ring_bytes * 2);  /* answers are bigger than questions */
    }
}

void ipc_wake(int efd) {
    uint64_t one = 1;
    while (write(efd, &one, sizeof one) < 0 && errno == EINTR) {}
}
