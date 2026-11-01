#ifndef CORE_ARENA_H
#define CORE_ARENA_H

#include <stddef.h>

/* per-req bump arena: blocks on demand, never moved, so ptrs stay valid until
 * reset; allocs 8-byte aligned, calloc zero-fills */

typedef struct arena_block arena_block;

typedef struct arena {
    arena_block *head;
} arena;

void arena_init(arena *a);
void arena_reset(arena *a);

void *arena_alloc(arena *a, size_t n);
void *arena_calloc(arena *a, size_t n);
char *arena_str(arena *a, const char *s, size_t n);
char *arena_strdup(arena *a, const char *s);

// two vsnprintf passes, one alloc
char *arena_printf(arena *a, const char *fmt, ...)
__attribute__((format(printf, 2, 3), nonnull(2)));

#endif
