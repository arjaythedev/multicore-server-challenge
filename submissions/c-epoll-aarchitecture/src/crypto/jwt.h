#ifndef CRYPTO_JWT_H
#define CRYPTO_JWT_H

#include <stdbool.h>

#include "core/buf.h"

/* HS256 per SPEC: {"sub":"<id>","iat":<now>,"exp":<now+30d>}; nothing cached */

#define JWT_TTL_SECONDS 2592000

/* compact serialization -> out; false on internal failure */
bool jwt_mint(buf *out, long long user_id, const char *secret,
              long long now_seconds);

/* true only for a correctly signed, unexpired token with this claim contract;
 * *user_id = sub */
bool jwt_verify(long long *user_id, const char *token, const char *secret);

#endif
