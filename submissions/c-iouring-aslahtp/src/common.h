/* Shared helpers: integer types, branch hints, byte-order loads and stores, aborting allocators. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define likely(x) __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)
#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
#define LIT(s) (s), (sizeof(s) - 1)

static inline uint32_t load_be32(const void *p) {
    const uint8_t *b = p;
    return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3];
}
static inline uint16_t load_be16(const void *p) {
    const uint8_t *b = p;
    return (uint16_t)(b[0] << 8 | b[1]);
}
static inline uint64_t load_be64(const void *p) {
    return (uint64_t)load_be32(p) << 32 | load_be32((const uint8_t *)p + 4);
}
static inline void store_be32(void *p, uint32_t v) {
    uint8_t *b = p;
    b[0] = v >> 24, b[1] = v >> 16, b[2] = v >> 8, b[3] = v;
}
static inline void store_be16(void *p, uint16_t v) {
    uint8_t *b = p;
    b[0] = v >> 8, b[1] = v;
}
static inline void store_be64(void *p, uint64_t v) {
    store_be32(p, v >> 32);
    store_be32((uint8_t *)p + 4, (uint32_t)v);
}

/* Running out of memory loses the run anyway, so allocation failure is fatal and callers never check. */
__attribute__((noreturn)) void die(const char *fmt, ...);
void *xmalloc(size_t n);
void *xcalloc(size_t n, size_t size);
void *xrealloc(void *p, size_t n);

/* Constant-time comparison, for signatures and hashes. */
static inline bool ct_equal(const void *a, const void *b, size_t n) {
    const uint8_t *x = a, *y = b;
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++) d |= x[i] ^ y[i];
    return d == 0;
}
