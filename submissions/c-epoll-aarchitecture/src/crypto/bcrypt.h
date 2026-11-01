#ifndef CRYPTO_BCRYPT_H
#define CRYPTO_BCRYPT_H

#include <stdbool.h>
#include <stddef.h>

/* bcrypt cost 10 via libxcrypt crypt_r; fresh 16-byte CSPRNG salt per hash,
 * real KDF per verify */

#define BCRYPT_COST         10      // pinned by the challenge rules
#define BCRYPT_HASH_MAX     64      // "$2b$10$" + 22 salt + 31 digest + NUL
#define BCRYPT_PASSWORD_MAX 72      // bcrypt truncates past 72 bytes

bool bcrypt_hash(char *out, size_t out_cap, const char *password);

typedef enum {
    BCRYPT_MATCH = 0,
    BCRYPT_MISMATCH = 1,
    BCRYPT_INVALID_HASH = -1,
} bcrypt_result;

bcrypt_result bcrypt_verify(const char *password, const char *stored_hash);

#endif
