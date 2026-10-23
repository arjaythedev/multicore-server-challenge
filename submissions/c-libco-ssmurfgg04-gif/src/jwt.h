/* jwt.h - HS256 verification with a key fixed at startup (Conduit scheme) */
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int64_t uid;       /* "sub": user id as a decimal string */
} auth_t;

void jwt_init(const char *secret, size_t secret_len);

/* Verifies "Authorization: Token <jwt>".
 * Returns 0 on success, 1 missing/malformed header, 2 invalid or expired
 * token (bad signature, wrong alg, expired), 3 valid signature but bad payload. */
int check_auth(const char *h, size_t hn, double now, auth_t *a);

/* Issues a token: {"sub":"<uid>","iat":<now>,"exp":<now+30d>}. Returns length. */
size_t jwt_issue(int64_t uid, double now, char *out, size_t cap);

/* exposed for selftests and the benchmark trainer */
void hmac_sha256_str(const char *msg, size_t mlen, uint8_t out[32]);
void jwt_b64url_init(void);
