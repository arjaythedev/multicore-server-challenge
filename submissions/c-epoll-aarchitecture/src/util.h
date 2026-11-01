#ifndef UTIL_H
#define UTIL_H

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

/* two failure modes (AGENTS.md):
 *   FATAL/CHECK  unrecoverable startup or invariant violation: print, stop
 *   return       anything a client can cause (bad input, failed stmt, closed
 *                peer) goes back to the caller for an HTTP response
 * alloc helpers are the invariant side: OOM has no safe state to answer from */

#define FATAL(...)                                                             \
    do {                                                                       \
        fprintf(stderr, __VA_ARGS__);                                          \
        fputc('\n', stderr);                                                   \
        exit(1);                                                               \
    } while (0)

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) FATAL(__VA_ARGS__);                                       \
    } while (0)

static inline void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) FATAL("out of memory");
    return p;
}

static inline void *xcalloc(size_t n, size_t size) {
    void *p = calloc(n ? n : 1, size ? size : 1);
    if (!p) FATAL("out of memory");
    return p;
}

static inline void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) FATAL("out of memory");
    return q;
}

#endif
