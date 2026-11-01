#include "crypto/bcrypt.h"

#include <crypt.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <string.h>

/* bcrypt's own base64 (./A-Z a-z0-9), not RFC 4648; 16 salt bytes = 22 chars */

static const char B64[] =
    "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static bool make_salt(char salt[23]) {
    unsigned char raw[16];
    if (RAND_bytes(raw, (int)sizeof raw) != 1) return false;

    unsigned bits = 0;
    unsigned nbits = 0;
    size_t out = 0;
    for (size_t i = 0; i < sizeof raw && out < 22; i++) {
        bits = (bits << 8) | raw[i];
        nbits += 8;
        while (nbits >= 6 && out < 22) {
            nbits -= 6;
            salt[out++] = B64[(bits >> nbits) & 0x3F];
        }
    }
    if (out < 22) {
        salt[out++] = B64[(bits << (6 - nbits)) & 0x3F];
    }
    salt[22] = '\0';
    return out == 22;
}

bool bcrypt_hash(char *out, size_t out_cap, const char *password) {
    if (out_cap < BCRYPT_HASH_MAX) return false;
    if (strlen(password) > BCRYPT_PASSWORD_MAX) return false;

    char salt[23];
    if (!make_salt(salt)) return false;

    char setting[32];
    int n = snprintf(setting, sizeof setting, "$2b$%02d$%s", BCRYPT_COST, salt);
    if (n != 29) return false;

    struct crypt_data data;
    memset(&data, 0, sizeof data);
    const char *result = crypt_r(password, setting, &data);
    if (!result || result[0] == '*' || strlen(result) != 60) return false;

    memcpy(out, result, 60);
    out[60] = '\0';
    return true;
}

bcrypt_result bcrypt_verify(const char *password, const char *stored_hash) {
    size_t stored_len = strlen(stored_hash);
    if (stored_len != 60 || stored_hash[0] != '$') return BCRYPT_INVALID_HASH;

    struct crypt_data data;
    memset(&data, 0, sizeof data);
    const char *result = crypt_r(password, stored_hash, &data);
    if (!result || result[0] == '*' || strlen(result) != 60)
        return BCRYPT_INVALID_HASH;

    unsigned char diff = 0;
    for (size_t i = 0; i < 60; i++)
        diff |= (unsigned char)(result[i] ^ stored_hash[i]);
    return diff ? BCRYPT_MISMATCH : BCRYPT_MATCH;
}
