/* Growable byte buffer, used for responses and Postgres messages. Writers reserve space first and then fill it,
 * so the hot paths are a bounds check and a memcpy. */
#pragma once
#include "common.h"

struct buf {
    char *p;
    size_t len, cap;
};

void buf_init(struct buf *b, size_t cap);
void buf_free(struct buf *b);
void buf_grow(struct buf *b, size_t need);

/* Makes room for n more bytes and returns where they go; the caller advances len. */
static inline char *buf_reserve(struct buf *b, size_t n) {
    if (unlikely(b->cap - b->len < n)) buf_grow(b, n);
    return b->p + b->len;
}
static inline void buf_put(struct buf *b, const void *src, size_t n) {
    memcpy(buf_reserve(b, n), src, n);
    b->len += n;
}
static inline void buf_putc(struct buf *b, char c) {
    *buf_reserve(b, 1) = c;
    b->len++;
}
#define buf_lit(b, s) buf_put((b), (s), sizeof(s) - 1)

/* Decimal digits of v into out (at least 20 bytes); returns the count. */
size_t fmt_u64(char *out, uint64_t v);
void buf_put_u64(struct buf *b, uint64_t v);
void buf_put_i64(struct buf *b, int64_t v);
