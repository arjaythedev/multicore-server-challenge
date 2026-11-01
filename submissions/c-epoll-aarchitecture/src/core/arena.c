#include "core/arena.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "config.h"
#include "util.h"

#define ARENA_ALIGN 8u

struct arena_block {
    arena_block *next;
    size_t used;
    size_t cap;
    char data[];
};

void arena_init(arena *a) {
    a->head = NULL;
}

void arena_reset(arena *a) {
    arena_block *b = a->head;
    while (b) {
        arena_block *next = b->next;
        free(b);
        b = next;
    }
    a->head = NULL;
}

void *arena_alloc(arena *a, size_t n) {
    if (n == 0) n = 1;
    CHECK(n <= SIZE_MAX - ARENA_ALIGN, "arena allocation overflow");
    n = (n + ARENA_ALIGN - 1) & ~(size_t)(ARENA_ALIGN - 1);

    arena_block *b = a->head;
    if (!b || b->cap - b->used < n) {
        size_t cap = n > ARENA_BLOCK_BYTES ? n : ARENA_BLOCK_BYTES;
        b = xmalloc(sizeof *b + cap);
        b->next = a->head;
        b->used = 0;
        b->cap = cap;
        a->head = b;
    }
    void *p = b->data + b->used;
    b->used += n;
    return p;
}

void *arena_calloc(arena *a, size_t n) {
    void *p = arena_alloc(a, n);
    memset(p, 0, n);
    return p;
}

char *arena_str(arena *a, const char *s, size_t n) {
    char *out = arena_alloc(a, n + 1);
    memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

char *arena_strdup(arena *a, const char *s) {
    return arena_str(a, s, strlen(s));
}

char *arena_printf(arena *a, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list measure;
    va_copy(measure, ap);
    int n = vsnprintf(NULL, 0, fmt, measure);
    va_end(measure);
    CHECK(n >= 0, "arena_printf: formatting failed");

    char *out = arena_alloc(a, (size_t)n + 1);
    int written = vsnprintf(out, (size_t)n + 1, fmt, ap);
    va_end(ap);
    CHECK(written == n, "arena_printf: length changed between passes");
    return out;
}
