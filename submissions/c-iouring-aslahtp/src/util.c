#include "util.h"

#include <stdarg.h>

void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    abort();
}

void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (unlikely(!p)) die("out of memory (%zu bytes)", n);
    return p;
}

void *xcalloc(size_t n, size_t size) {
    void *p = calloc(n ? n : 1, size ? size : 1);
    if (unlikely(!p)) die("out of memory (%zu x %zu bytes)", n, size);
    return p;
}

void *xrealloc(void *p, size_t n) {
    p = realloc(p, n ? n : 1);
    if (unlikely(!p)) die("out of memory (%zu bytes)", n);
    return p;
}

bool parse_uint(const char *s, size_t n, int64_t *out) {
    uint64_t v = 0;
    if (n == 0) return false;
    for (size_t i = 0; i < n; i++) {
        unsigned d = (unsigned char)s[i] - '0';
        if (d > 9) return false;
        if (v > (UINT64_C(0x7fffffffffffffff) - d) / 10) return false;
        v = v * 10 + d;
    }
    *out = (int64_t)v;
    return true;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

ptrdiff_t pct_decode(char *dst, const char *src, size_t n, bool plus_space) {
    char *d = dst;
    for (size_t i = 0; i < n; i++) {
        char c = src[i];
        if (c == '%') {
            if (n - i < 3) return -1;
            int hi = hexval(src[i + 1]), lo = hexval(src[i + 2]);
            if (hi < 0 || lo < 0) return -1;
            *d++ = (char)(hi << 4 | lo);
            i += 2;
        } else if (c == '+' && plus_space) {
            *d++ = ' ';
        } else {
            *d++ = c;
        }
    }
    return d - dst;
}
