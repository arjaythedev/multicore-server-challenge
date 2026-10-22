#ifndef CONDUIT_PASSWORD_H
#define CONDUIT_PASSWORD_H
#include <stddef.h>
#include <stdint.h>
enum { CONDUIT_HASH = 0, CONDUIT_VERIFY = 1 };
enum {
    CONDUIT_HASHED = 1, CONDUIT_VERIFIED = 2,
    CONDUIT_REJECTED = 3, CONDUIT_FAILED = 4
};
int conduit_hash(const uint8_t *, size_t, uint8_t *);
int conduit_verify(const uint8_t *, size_t, const uint8_t *, size_t);
/* Descriptor arrays contain count (1..4) entries. Hash outputs are 60 bytes
 * without a terminator; verification outputs may be NULL. execution has two
 * size_t entries: user interleaved/scalar counts, excluding runtime guards.
 * Zero rejects descriptors without writes; one initializes every lane status.
 * Inputs are borrowed until return; no pointers are retained.
 */
int conduit_password_batch(size_t count, const uint8_t *kinds,
    const uint8_t *const *passwords, const size_t *lengths,
    const uint8_t *const *hashes, const size_t *hash_lengths,
    uint8_t *const *outputs, uint8_t *statuses, size_t *execution);
#endif
