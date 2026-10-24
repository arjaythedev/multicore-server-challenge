/* conduit-bcrypt: the server's bcrypt kernel in C, called once per batch of logins (JVM: FFM; Kotlin/Native:
 * cinterop). Up to 8 independent hashes of one cost run with their Blowfish rounds interleaved, so the CPU overlaps
 * their dependent S-box loads: 8 hashes cost ~2.1x one. The bcrypt code is the vendored, unchanged Openwall core
 * (crypt-bcrypt.c) and its 2-4 lane interleave (bcrypt-batch.c, bcrypt-batch-impl.h); see README.md. */
#ifndef CONDUIT_BCRYPT_H
#define CONDUIT_BCRYPT_H

#include <stdint.h>

/* Lanes per call at most. */
#define CONDUIT_BF_MAX_LANES 8

/*
 * Computes n (1..8) bcrypt hashes of the same cost (0..31) from words the caller has prepared:
 *   keys:  n x 18 words, the password bytes plus a NUL, cycled to 72 bytes, as big-endian words (bcrypt's expanded
 *          key). The caller builds them from the bytes, so a password with an embedded NUL is hashed correctly
 *          (crypt(3) would stop at the NUL).
 *   salts: n x 4 words, the 16 salt bytes as big-endian words.
 *   out:   n x 6 words, "OrpheanBeholderScryDoubt" encrypted 64 times: the 24 raw bytes as big-endian words (a
 *          hash string encodes the first 23).
 * The result is that of $2b$ and $2y$ (and $2a$, which differs only for keys with 0xff bytes, never in UTF-8).
 * n = 1, 2, 3, 4, 6 and 8 run the kernel of that width; 5 and 7 run the 6- and 8-lane kernels, idle lanes repeating
 * lane 0. Returns 1, or 0 for a bad n or cost. Reentrant; uses ~35 KB of stack, wiped before returning.
 */
int conduit_bf_lanes(int n, const int32_t *keys, const int32_t *salts, int cost, int32_t *out);

/*
 * Checks conduit_bf_lanes for every n (1..8) against the single-hash Openwall crypt (crypt_bcrypt_rn, which runs
 * Openwall's own built-in self-test as well) on known keys, with different keys and salts in every lane. Returns 0
 * if all match, -1 if the reference failed, else the first failing n.
 */
int conduit_bf_self_test(void);

#endif
