#ifndef CORE_BUF_H
#define CORE_BUF_H

#include <stddef.h>

/* growable byte buf; owns data (or empty, data==NULL). buf_free is the only
 * destructor. realloc can move data: buf_reserve ptrs valid only until the
 * next append */

typedef struct buf {
    char *data;
    size_t len;
    size_t cap;
} buf;

void buf_init(buf *b);
void buf_free(buf *b);
void buf_clear(buf *b);

// room for `extra` bytes past len
void buf_reserve(buf *b, size_t extra);

// append raw bytes; p NULL only if n==0
void buf_append(buf *b, const void *p, size_t n);
void buf_putc(buf *b, char c);

// printf into buf; vsnprintf's NUL stays in reserved cap, not counted in len
void buf_printf(buf *b, const char *fmt, ...)
__attribute__((format(printf, 2, 3), nonnull(2)));

// drop first n bytes (partial socket writes)
void buf_consume(buf *b, size_t n);

// append a decimal integer; hand-rolled, no printf machinery
void buf_num(buf *b, long long v);

#define BUF_LIT(b, lit) buf_append((b), (lit), sizeof(lit) - 1)

#endif
