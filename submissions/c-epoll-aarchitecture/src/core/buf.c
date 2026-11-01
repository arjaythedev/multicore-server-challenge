#include "core/buf.h"

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "config.h"
#include "util.h"

void buf_init(buf *b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

void buf_free(buf *b) {
    free(b->data);
    buf_init(b);
}

void buf_clear(buf *b) {
    b->len = 0;
}

void buf_reserve(buf *b, size_t extra) {
    if (extra <= b->cap - b->len) return;
    CHECK(extra <= SIZE_MAX - b->len, "buffer length overflow");
    size_t need = b->len + extra;
    size_t cap = b->cap ? b->cap : BUF_MIN_CAPACITY;
    while (cap < need) {
        CHECK(cap <= SIZE_MAX / 2, "buffer capacity overflow");
        cap *= 2;
    }
    b->data = xrealloc(b->data, cap);
    b->cap = cap;
}

void buf_append(buf *b, const void *p, size_t n) {
    if (n == 0) return;
    CHECK(p != NULL, "buf_append: NULL source");
    buf_reserve(b, n);
    memcpy(b->data + b->len, p, n);
    b->len += n;
}

void buf_putc(buf *b, char c) {
    buf_reserve(b, 1);
    b->data[b->len++] = c;
}

void buf_printf(buf *b, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list measure;
    va_copy(measure, ap);
    int n = vsnprintf(NULL, 0, fmt, measure);
    va_end(measure);
    CHECK(n >= 0, "buf_printf: formatting failed");

    size_t at = b->len;
    size_t need = (size_t)n + 1;      // vsnprintf writes a NUL
    buf_reserve(b, need);
    int written = vsnprintf(b->data + at, need, fmt, ap);
    va_end(ap);
    CHECK(written == n, "buf_printf: length changed between passes");
    b->len = at + (size_t)n;
}

void buf_consume(buf *b, size_t n) {
    CHECK(n <= b->len, "buf_consume past end");
    if (n == 0) return;
    size_t left = b->len - n;
    if (left) memmove(b->data, b->data + n, left);
    b->len = left;
}

void buf_num(buf *b, long long v) {
    bool neg = v < 0;
    unsigned long long u =
        neg ? -(unsigned long long)v : (unsigned long long)v;
    char tmp[24];
    size_t i = sizeof tmp;
    do {
        tmp[--i] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    if (neg) tmp[--i] = '-';
    buf_append(b, tmp + i, sizeof tmp - i);
}
