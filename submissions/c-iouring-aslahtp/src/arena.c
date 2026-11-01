#include "arena.h"

struct arena_chunk {
    struct arena_chunk *next;  /* older chunk */
    size_t size;
    _Alignas(16) char data[];
};

static struct arena_chunk *chunk_new(size_t size, struct arena_chunk *next) {
    struct arena_chunk *c = xmalloc(sizeof *c + size);
    c->next = next;
    c->size = size;
    return c;
}

void arena_init(struct arena *a, size_t chunk_size) {
    a->chunk_size = chunk_size;
    a->head = chunk_new(chunk_size, NULL);
    a->cur = a->head->data;
    a->end = a->cur + chunk_size;
}

void *arena_alloc_slow(struct arena *a, size_t n) {
    size_t size = n > a->chunk_size ? n : a->chunk_size;
    a->head = chunk_new(size, a->head);
    a->cur = a->head->data + n;
    a->end = a->head->data + size;
    return a->head->data;
}

void arena_reset(struct arena *a) {
    while (a->head->next) {
        struct arena_chunk *older = a->head->next;
        free(a->head);
        a->head = older;
    }
    a->cur = a->head->data;
    a->end = a->cur + a->head->size;
}

void arena_free(struct arena *a) {
    arena_reset(a);
    free(a->head);
    a->head = NULL;
    a->cur = a->end = NULL;
}
