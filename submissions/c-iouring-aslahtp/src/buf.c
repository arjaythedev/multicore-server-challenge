#include "buf.h"

void buf_init(struct buf *b, size_t cap) {
    b->p = xmalloc(cap);
    b->len = 0;
    b->cap = cap;
}

void buf_free(struct buf *b) {
    free(b->p);
    b->p = NULL;
    b->len = b->cap = 0;
}

void buf_grow(struct buf *b, size_t need) {
    size_t cap = b->cap ? b->cap : 256;
    while (cap - b->len < need) cap *= 2;
    b->p = xrealloc(b->p, cap);
    b->cap = cap;
}

static const char digits2[200] =
    "00010203040506070809101112131415161718192021222324252627282930313233343536373839"
    "40414243444546474849505152535455565758596061626364656667686970717273747576777879"
    "8081828384858687888990919293949596979899";

size_t fmt_u64(char *out, uint64_t v) {
    char tmp[20];
    char *p = tmp + sizeof tmp;
    while (v >= 100) {
        unsigned d = (unsigned)(v % 100) * 2;
        v /= 100;
        *--p = digits2[d + 1];
        *--p = digits2[d];
    }
    if (v >= 10) {
        *--p = digits2[v * 2 + 1];
        *--p = digits2[v * 2];
    } else {
        *--p = (char)('0' + v);
    }
    size_t n = (size_t)(tmp + sizeof tmp - p);
    memcpy(out, p, n);
    return n;
}

void buf_put_u64(struct buf *b, uint64_t v) {
    b->len += fmt_u64(buf_reserve(b, 20), v);
}

void buf_put_i64(struct buf *b, int64_t v) {
    if (v < 0) {
        buf_putc(b, '-');
        buf_put_u64(b, (uint64_t)0 - (uint64_t)v);
    } else {
        buf_put_u64(b, (uint64_t)v);
    }
}
