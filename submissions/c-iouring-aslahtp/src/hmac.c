#include "hmac.h"

void hmac_key_init(struct hmac_key *k, const void *key, size_t n) {
    uint8_t block[SHA256_BLOCK] = {0}, pad[SHA256_BLOCK];
    if (n > SHA256_BLOCK) sha256(key, n, block);
    else memcpy(block, key, n);

    for (int i = 0; i < SHA256_BLOCK; i++) pad[i] = block[i] ^ 0x36;
    sha256_init(&k->inner);
    sha256_update(&k->inner, pad, sizeof pad);
    for (int i = 0; i < SHA256_BLOCK; i++) pad[i] = block[i] ^ 0x5c;
    sha256_init(&k->outer);
    sha256_update(&k->outer, pad, sizeof pad);
}

void hmac_sha256_k(const struct hmac_key *k, const void *msg, size_t n, uint8_t out[SHA256_LEN]) {
    struct sha256 s = k->inner;
    uint8_t ih[SHA256_LEN];
    sha256_update(&s, msg, n);
    sha256_final(&s, ih);
    s = k->outer;
    sha256_update(&s, ih, sizeof ih);
    sha256_final(&s, out);
}

void hmac_sha256(const void *key, size_t klen, const void *msg, size_t n, uint8_t out[SHA256_LEN]) {
    struct hmac_key k;
    hmac_key_init(&k, key, klen);
    hmac_sha256_k(&k, msg, n, out);
}

void pbkdf2_sha256(const void *pw, size_t pwlen, const void *salt, size_t saltlen, uint32_t iters,
                   uint8_t out[SHA256_LEN]) {
    struct hmac_key k;
    struct sha256 s;
    uint8_t u[SHA256_LEN];
    static const uint8_t block_index[4] = {0, 0, 0, 1};

    hmac_key_init(&k, pw, pwlen);
    s = k.inner;
    sha256_update(&s, salt, saltlen);
    sha256_update(&s, block_index, sizeof block_index);
    sha256_final(&s, u);
    s = k.outer;
    sha256_update(&s, u, sizeof u);
    sha256_final(&s, u);
    memcpy(out, u, SHA256_LEN);

    for (uint32_t i = 1; i < iters; i++) {
        hmac_sha256_k(&k, u, sizeof u, u);
        for (int j = 0; j < SHA256_LEN; j++) out[j] ^= u[j];
    }
}
