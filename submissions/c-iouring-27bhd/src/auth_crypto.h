#ifndef AUTH_CRYPTO_H
#define AUTH_CRYPTO_H

#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <crypt.h>

typedef struct {
    uint32_t state[8];
    uint64_t count;
    uint8_t buffer[64];
} sha256_ctx_t;

typedef struct {
    uint32_t inner_state[8];
    uint32_t outer_state[8];
} hmac_midstate_t;

extern hmac_midstate_t g_jwt_hmac;

void auth_init(const char *secret);
int jwt_issue(int64_t user_id, char *out_token);
int64_t jwt_verify(const char *token);
bool hash_password(const char *pw, char *out_hash, size_t out_hash_size);
bool verify_password(const char *pw, const char *stored_hash);

int b64url_encode(const uint8_t *in, int in_len, char *out);
int b64url_decode(const char *in, int in_len, uint8_t *out);

#endif // AUTH_CRYPTO_H
