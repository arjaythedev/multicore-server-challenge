/* bcrypt ("$2a$" / "$2b$" / "$2y$"), as Go's golang.org/x/crypto/bcrypt computes it: the key is the password plus
 * its NUL terminator, used cyclically over 72 bytes. Passwords over 72 bytes are refused by the API layer (422).
 *
 * This is the single-lane reference implementation. The interleaved kernels (plan M8) must match it bit for bit. */
#pragma once
#include "common.h"

#define BCRYPT_LEN 60          /* "$2a$10$" + 22 salt chars + 31 hash chars */
#define BCRYPT_SALT 16
#define BCRYPT_RAW 23          /* hash bytes kept from the 24-byte ciphertext */
#define BCRYPT_MAX_PW 72

/* A parsed stored hash. */
struct bcrypt_setting {
    char minor;                /* 'a', 'b', 'y', or 0 for "$2$" */
    int cost;
    uint8_t salt[BCRYPT_SALT];
    char hash[31];             /* the stored hash, still encoded */
};

bool bcrypt_parse(const char *h, size_t n, struct bcrypt_setting *s);

/* The core: 2^cost rounds of the expensive key schedule, then 64 encryptions of "OrpheanBeholderScryDoubt". */
void bcrypt_raw(const char *pw, size_t pwlen, const uint8_t salt[BCRYPT_SALT], int cost, uint8_t out[BCRYPT_RAW]);

/* The same for several hashes of one cost at once (bcrypt_lanes.c): out[i] is bcrypt_raw of in[i]. */
#define BCRYPT_LANES_MAX 8
struct bcrypt_lane {
    const char *pw;
    size_t pwlen;
    const uint8_t *salt;
};
void bcrypt_raw_lanes(const struct bcrypt_lane *in, int n, int cost, uint8_t (*out)[BCRYPT_RAW]);

/* Formats "$2a$CC$<salt><hash>" (60 characters, NUL-terminated). */
void bcrypt_hash(const char *pw, size_t pwlen, int cost, const uint8_t salt[BCRYPT_SALT], char out[BCRYPT_LEN + 1]);

/* True if pw matches the stored hash. False for a malformed hash. */
bool bcrypt_verify(const char *pw, size_t pwlen, const char *hash, size_t n);

/* bcrypt's own base64 alphabet ("./A-Za-z0-9"), no padding. */
size_t bcrypt_b64_encode(char *dst, const uint8_t *src, size_t n);
bool bcrypt_b64_decode(uint8_t *dst, size_t dstlen, const char *src, size_t n);
