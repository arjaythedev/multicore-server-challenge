#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "crypt_blowfish.h"

int conduit_hash(const uint8_t *password, size_t length, uint8_t *output);
int conduit_verify(const uint8_t *password, size_t length,
                   const uint8_t *hash, size_t hash_length);

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "password test failed at line %d\n", __LINE__); \
        return 1; \
    } \
} while (0)

static int check_reference(const uint8_t *password, size_t length,
                           const char *expected)
{
    char actual[61];
    const char *salt = "$2b$10$......................";
    CHECK(_crypt_blowfish_len_rn((const char *)password, length, salt,
                                 actual, sizeof(actual)) != NULL);
    CHECK(memcmp(actual, expected, 60) == 0);
    CHECK(conduit_verify(password, length, (const uint8_t *)expected, 60));
    return 0;
}

int main(void)
{
    static const char empty[] =
        "$2b$10$......................F5mzCEQ5E01or2Zs1UUMeqS/7rfVb16";
    static const char ascii[] =
        "$2b$10$......................naFBfND/0rjnzNKXE2KCY4zIW5UdykO";
    static const char nul[] =
        "$2b$10$......................a2md9ZUXOMO5mFpVaptzVNswqH//l/y";
    static const char utf8[] =
        "$2b$10$......................fiFpKnksqdh4kPbcKBE07aRafSx.Ybu";
    static const char exact72[] =
        "$2b$10$......................91k3FJPPs0jml5HfHe6SwQyUIeHcrta";
    static const uint8_t nul_password[] = {'a', 0, 'b'};
    static const uint8_t other_nul_password[] = {'a', 0, 'c'};
    static const uint8_t utf8_password[] =
        {'p', 0xc3, 0xa4, 's', 's', 'w', 0xc3, 0xb6, 'r', 'd'};
    uint8_t long_password[73];
    uint8_t generated[60];
    char variant[61];
    const char prefixes[] = {'a', 'b', 'x', 'y'};
    size_t i;

    CHECK(check_reference((const uint8_t *)"", 0, empty) == 0);
    CHECK(check_reference((const uint8_t *)"password123", 11, ascii) == 0);
    CHECK(check_reference(nul_password, sizeof(nul_password), nul) == 0);
    CHECK(check_reference(utf8_password, sizeof(utf8_password), utf8) == 0);
    memset(long_password, 'p', sizeof(long_password));
    CHECK(check_reference(long_password, 72, exact72) == 0);
    CHECK(conduit_verify(long_password, 73, (const uint8_t *)exact72, 60));
    CHECK(!conduit_hash(long_password, 73, generated));
    CHECK(!conduit_verify((const uint8_t *)"a", 1,
                          (const uint8_t *)nul, 60));
    CHECK(!conduit_verify(other_nul_password, sizeof(other_nul_password),
                          (const uint8_t *)nul, 60));
    CHECK(!conduit_verify((const uint8_t *)"password124", 11,
                          (const uint8_t *)ascii, 60));
    CHECK(!conduit_verify((const uint8_t *)"password123", 11,
                          (const uint8_t *)ascii, 59));
    memcpy(variant, ascii, sizeof(variant));
    variant[28] = '/';
    CHECK(!conduit_verify((const uint8_t *)"password123", 11,
                          (const uint8_t *)variant, 60));
    memcpy(variant, ascii, sizeof(variant));
    variant[59] = 'P';
    CHECK(!conduit_verify((const uint8_t *)"password123", 11,
                          (const uint8_t *)variant, 60));
    memcpy(variant, ascii, sizeof(variant));
    variant[2] = 'c';
    CHECK(!conduit_verify((const uint8_t *)"password123", 11,
                          (const uint8_t *)variant, 60));
    memcpy(variant, ascii, sizeof(variant));
    variant[5] = '3';
    CHECK(!conduit_verify((const uint8_t *)"password123", 11,
                          (const uint8_t *)variant, 60));
    memcpy(variant, ascii, sizeof(variant));
    variant[7] = '!';
    CHECK(!conduit_verify((const uint8_t *)"password123", 11,
                          (const uint8_t *)variant, 60));
    memcpy(variant, ascii, sizeof(variant));
    variant[10] = '\0';
    CHECK(!conduit_verify((const uint8_t *)"password123", 11,
                          (const uint8_t *)variant, 60));
    for (i = 0; i < sizeof(prefixes); i++) {
        memcpy(variant, utf8, sizeof(variant));
        variant[2] = prefixes[i];
        CHECK(conduit_verify(utf8_password, sizeof(utf8_password),
                             (const uint8_t *)variant, 60));
    }
    CHECK(conduit_hash((const uint8_t *)"password123", 11, generated));
    CHECK(memcmp(generated, "$2b$10$", 7) == 0);
    CHECK(conduit_verify((const uint8_t *)"password123", 11,
                         generated, sizeof(generated)));
    puts("C bcrypt tests passed");
    return 0;
}
