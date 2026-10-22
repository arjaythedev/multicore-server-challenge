#include "password.h"

int conduit_password_test_batch(size_t count, const uint8_t *kinds,
    const uint8_t *const *passwords, const size_t *lengths,
    const uint8_t *const *hashes, const size_t *hash_lengths,
    uint8_t *const *outputs, uint8_t *statuses, size_t *execution,
    int reject)
{
    if (reject) return 0;
    return conduit_password_batch(count, kinds, passwords, lengths, hashes,
        hash_lengths, outputs, statuses, execution);
}
