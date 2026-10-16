#include <openssl/rand.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "crypt_blowfish.h"

int conduit_hash(const uint8_t *password, size_t length, uint8_t *output)
{
    unsigned char salt[16];
    char setting[30];
    char hash[61];

    if (length > 72 || RAND_bytes(salt, sizeof(salt)) != 1)
        return 0;
    if (!_crypt_gensalt_blowfish_rn("$2b$", 10, (const char *)salt,
                                    sizeof(salt), setting, sizeof(setting)))
        return 0;
    if (!_crypt_blowfish_len_rn((const char *)password, length, setting,
                                hash, sizeof(hash)))
        return 0;
    memcpy(output, hash, 60);
    return 1;
}

int conduit_verify(const uint8_t *password, size_t length,
                   const uint8_t *hash, size_t hash_length)
{
    static const char alphabet[] =
        "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    char setting[61];
    char computed[61];
    unsigned char expected[23];
    unsigned char actual[23];
    const char *salt_tail;
    const char *hash_tail;
    unsigned int diff = 0;
    size_t i;

    if (hash_length != 60 || hash[0] != '$' || hash[1] != '2' ||
        (hash[2] != 'a' && hash[2] != 'b' &&
         hash[2] != 'x' && hash[2] != 'y') || hash[3] != '$')
        return 0;
    memcpy(setting, hash, 60);
    setting[60] = '\0';
    if (memchr(setting, '\0', 60) != NULL)
        return 0;
    salt_tail = strchr(alphabet, setting[28]);
    hash_tail = strchr(alphabet, setting[59]);
    if (salt_tail == NULL || hash_tail == NULL ||
        ((salt_tail - alphabet) & 15) != 0 ||
        ((hash_tail - alphabet) & 3) != 0)
        return 0;
    setting[2] = 'b';
    if (!_crypt_blowfish_len_rn((const char *)password, length, setting,
                                computed, sizeof(computed)))
        return 0;
    if (_crypt_blowfish_decode(setting + 29, expected, 23) != 0 ||
        _crypt_blowfish_decode(computed + 29, actual, 23) != 0)
        return 0;
    for (i = 0; i < 23; i++)
        diff |= expected[i] ^ actual[i];
    return diff == 0;
}
