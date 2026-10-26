/* HMAC-SHA-256 (RFC 2104) and single-block PBKDF2-HMAC-SHA-256 (RFC 8018), for JWT and SCRAM. */
#pragma once
#include "sha256.h"

/* A key's inner and outer hash states after absorbing the padded key: each MAC then costs two fewer blocks. */
struct hmac_key {
    struct sha256 inner, outer;
};

void hmac_key_init(struct hmac_key *k, const void *key, size_t n);
void hmac_sha256_k(const struct hmac_key *k, const void *msg, size_t n, uint8_t out[SHA256_LEN]);
void hmac_sha256(const void *key, size_t klen, const void *msg, size_t n, uint8_t out[SHA256_LEN]);

/* PBKDF2 with a 32-byte output (one block), which is all SCRAM-SHA-256 needs. */
void pbkdf2_sha256(const void *pw, size_t pwlen, const void *salt, size_t saltlen, uint32_t iters,
                   uint8_t out[SHA256_LEN]);
