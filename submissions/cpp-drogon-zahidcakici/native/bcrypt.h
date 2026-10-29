#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#define BC_MAX_LANES 6
/* 1..6 hashes; keys are NUL-terminated (at most 72 bytes), settings "$2b$10$<22 salt chars>" or a stored hash.
 * 2..6 hashes must share one cost. Writes 60 characters + NUL per hash; returns 1 on success. */
int bc_hash(const char *const *keys, const char *const *settings, unsigned char (*out)[61], unsigned n);
int bc_selftest(void);
double bc_calibrate(unsigned n);
#ifdef __cplusplus
}
#endif
