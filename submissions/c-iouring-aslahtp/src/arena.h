/* Bump allocator for per-request scratch (parsed JSON bodies, decoded strings). One arena per event loop: a request
 * uses it while its handler runs synchronously, and the loop resets it before the next request. Nothing allocated
 * here may outlive that step; anything a request needs later is copied into the request itself. */
#pragma once
#include "common.h"

struct arena_chunk;

struct arena {
    char *cur, *end;
    struct arena_chunk *head;  /* newest chunk; the oldest (first) one is kept across resets */
    size_t chunk_size;
};

void arena_init(struct arena *a, size_t chunk_size);
void arena_reset(struct arena *a);
void arena_free(struct arena *a);
void *arena_alloc_slow(struct arena *a, size_t n);

/* 16-byte aligned. */
static inline void *arena_alloc(struct arena *a, size_t n) {
    n = (n + 15) & ~(size_t)15;
    if (likely((size_t)(a->end - a->cur) >= n)) {
        void *p = a->cur;
        a->cur += n;
        return p;
    }
    return arena_alloc_slow(a, n);
}
