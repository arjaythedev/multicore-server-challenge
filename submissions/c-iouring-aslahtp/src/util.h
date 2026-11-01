/* Small parsing helpers shared by the HTTP layer and handlers. */
#pragma once
#include "common.h"

/* ASCII digits only (no sign, no spaces, no empty string), fitting an int64; leading zeros allowed.
 * This is the reference server's rule for limit, offset and comment ids. */
bool parse_uint(const char *s, size_t n, int64_t *out);

/* Percent-decodes src into dst (dst may equal src); with plus_space, '+' becomes ' ' (query strings).
 * Returns the decoded length, or -1 for a malformed escape. */
ptrdiff_t pct_decode(char *dst, const char *src, size_t n, bool plus_space);
