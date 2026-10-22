#include <openssl/rand.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "crypt_blowfish.h"
#include "password.h"

static int prepare_hash(size_t length, char *setting)
{
    unsigned char salt[16];
    if (length > 72 || RAND_bytes(salt, sizeof(salt)) != 1) return 0;
    return _crypt_gensalt_blowfish_rn("$2b$", 10, (const char *)salt,
        sizeof(salt), setting, 30) != NULL;
}

static int prepare_verify(const uint8_t *hash, size_t length, char *setting)
{
    static const char alphabet[] =
        "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    unsigned char decoded[23];
    const char *salt_tail;
    const char *hash_tail;
    if (length != 60 || hash[0] != '$' || hash[1] != '2' ||
        (hash[2] != 'a' && hash[2] != 'b' &&
         hash[2] != 'x' && hash[2] != 'y') || hash[3] != '$') return 0;
    memcpy(setting, hash, 60);
    setting[60] = 0;
    if (memchr(setting, 0, 60)) return 0;
    salt_tail = strchr(alphabet, setting[28]);
    hash_tail = strchr(alphabet, setting[59]);
    if (!salt_tail || !hash_tail || ((salt_tail - alphabet) & 15) ||
        ((hash_tail - alphabet) & 3)) return 0;
    if (setting[4] < '0' || setting[4] > '3' || setting[5] < '0' ||
        setting[5] > '9' || setting[6] != '$') return 0;
    unsigned cost = (setting[4] - '0') * 10 + setting[5] - '0';
    if (cost < 4 || cost > 31 ||
        _crypt_blowfish_decode(setting + 7, decoded, 16) != 0 ||
        _crypt_blowfish_decode(setting + 29, decoded, 23) != 0) return 0;
    setting[2] = 'b';
    return 1;
}

static int finish_verify(const char *setting, const char *computed)
{
    unsigned char expected[23], actual[23];
    unsigned int diff = 0;
    if (_crypt_blowfish_decode(setting + 29, expected, 23) != 0 ||
        _crypt_blowfish_decode(computed + 29, actual, 23) != 0) return 0;
    for (size_t i = 0; i < 23; i++) diff |= expected[i] ^ actual[i];
    return diff == 0;
}

int conduit_hash(const uint8_t *password, size_t length, uint8_t *output)
{
    char setting[30], hash[61];
    if (!prepare_hash(length, setting) ||
        !_crypt_blowfish_len_rn((const char *)password, length, setting,
            hash, sizeof(hash))) return 0;
    memcpy(output, hash, 60);
    return 1;
}

int conduit_verify(const uint8_t *password, size_t length,
    const uint8_t *hash, size_t hash_length)
{
    char setting[61], computed[61];
    return prepare_verify(hash, hash_length, setting) &&
        _crypt_blowfish_len_rn((const char *)password, length, setting,
            computed, sizeof(computed)) && finish_verify(setting, computed);
}

int conduit_password_batch(size_t count, const uint8_t *kinds,
    const uint8_t *const *passwords, const size_t *lengths,
    const uint8_t *const *hashes, const size_t *hash_lengths,
    uint8_t *const *outputs, uint8_t *statuses, size_t *execution)
{
    if (count < 1 || count > 4 || !kinds || !passwords || !lengths ||
        !hashes || !hash_lengths || !outputs || !statuses || !execution)
        return 0;
    for (size_t i = 0; i < count; i++) {
        if (kinds[i] > CONDUIT_VERIFY || (!passwords[i] && lengths[i]) ||
            (!hashes[i] && hash_lengths[i]) ||
            (kinds[i] == CONDUIT_HASH && !outputs[i])) return 0;
    }
    char settings[4][61], computed[4][61];
    const char *keys[4], *salts[4];
    size_t sizes[4], indices[4], lanes = 0;
    unsigned char prepared[4] = {0};
    execution[0] = execution[1] = 0;
    for (size_t i = 0; i < count; i++) {
        statuses[i] = CONDUIT_FAILED;
        if (kinds[i] == CONDUIT_HASH) {
            if (!prepare_hash(lengths[i], settings[i])) continue;
        } else if (!prepare_verify(hashes[i], hash_lengths[i], settings[i])) {
            statuses[i] = CONDUIT_REJECTED;
            continue;
        }
        prepared[i] = 1;
        if (settings[i][4] == '1' && settings[i][5] == '0') {
            keys[lanes] = passwords[i] ? (const char *)passwords[i] : "";
            sizes[lanes] = lengths[i];
            salts[lanes] = settings[i];
            indices[lanes++] = i;
        }
    }
    if (lanes >= 2) {
        execution[0] = lanes;
        int okay = _crypt_blowfish_batch_rn(keys, sizes, salts, computed, lanes);
        for (size_t lane = 0; lane < lanes; lane++) {
            size_t i = indices[lane];
            prepared[i] = 0;
            if (!okay) continue;
            if (kinds[i] == CONDUIT_HASH) {
                memcpy(outputs[i], computed[lane], 60);
                statuses[i] = CONDUIT_HASHED;
            } else statuses[i] = finish_verify(settings[i], computed[lane]) ?
                CONDUIT_VERIFIED : CONDUIT_REJECTED;
        }
    }
    for (size_t i = 0; i < count; i++) {
        if (!prepared[i]) continue;
        execution[1]++;
        if (!_crypt_blowfish_len_rn(passwords[i] ?
                (const char *)passwords[i] : "", lengths[i], settings[i],
                computed[0], 61)) continue;
        if (kinds[i] == CONDUIT_HASH) {
            memcpy(outputs[i], computed[0], 60);
            statuses[i] = CONDUIT_HASHED;
        } else statuses[i] = finish_verify(settings[i], computed[0]) ?
            CONDUIT_VERIFIED : CONDUIT_REJECTED;
    }
    return 1;
}

int conduit_password_selftest(void)
{
    return _crypt_blowfish_batch_selftest();
}
