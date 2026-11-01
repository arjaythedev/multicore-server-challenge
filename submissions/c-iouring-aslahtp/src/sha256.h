/* SHA-256 (FIPS 180-4). The block function is a pointer so startup can switch to the SHA-NI version. */
#pragma once
#include "common.h"

#define SHA256_LEN 32
#define SHA256_BLOCK 64

struct sha256 {
    uint32_t h[8];
    uint64_t total;     /* bytes absorbed */
    uint8_t blk[SHA256_BLOCK];
    size_t blen;        /* bytes waiting in blk */
};

/* Compresses n whole 64-byte blocks into h. */
typedef void (*sha256_blocks_fn)(uint32_t h[8], const uint8_t *p, size_t n);
extern sha256_blocks_fn sha256_blocks;
void sha256_blocks_generic(uint32_t h[8], const uint8_t *p, size_t n);

/* Picks the fastest block function this CPU supports. Call once at startup. */
void sha256_select(void);

void sha256_init(struct sha256 *s);
void sha256_update(struct sha256 *s, const void *data, size_t n);
void sha256_final(struct sha256 *s, uint8_t out[SHA256_LEN]);
void sha256(const void *data, size_t n, uint8_t out[SHA256_LEN]);
