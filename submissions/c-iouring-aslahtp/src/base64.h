/* Base64: the URL-safe alphabet without padding (JWT) and the standard one with padding (SCRAM). */
#pragma once
#include "common.h"

#define B64_ENC_LEN(n) (((n) + 2) / 3 * 4)

/* Both encoders return the number of characters written. */
size_t b64url_encode(char *dst, const void *src, size_t n);
size_t b64_encode(char *dst, const void *src, size_t n);

/* Return the decoded length, or -1 for malformed input. dst needs room for n * 3 / 4 bytes.
 * Like Go's RawURLEncoding, the URL decoder rejects padding and does not insist that unused trailing bits are 0. */
ptrdiff_t b64url_decode(void *dst, const char *src, size_t n);
ptrdiff_t b64_decode(void *dst, const char *src, size_t n);
