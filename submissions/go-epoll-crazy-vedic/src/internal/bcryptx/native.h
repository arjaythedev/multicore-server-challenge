#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Input and output arrays are tightly packed: passwords use 73-byte slots,
// salts 16-byte slots, and hashes 60-byte slots.
int bcryptx_compute(const uint8_t *passwords, const int32_t *lengths,
                    const uint8_t *salts, const int32_t *costs,
                    uint8_t *hashes, int n);

#ifdef __cplusplus
}
#endif
