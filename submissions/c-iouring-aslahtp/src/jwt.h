/* HS256 JSON Web Tokens: {"sub": "<user id>", "iat": now, "exp": now + 30 days}.
 *
 * Verification follows the reference server (golang-jwt v5 with HS256 only and exp required): three segments, a
 * header whose alg is "HS256", a valid signature, a numeric exp in the future, nbf (if any) not in the future,
 * registered claims of the right JSON types, and sub a decimal string naming a positive id. */
#pragma once
#include "arena.h"

#define JWT_MAX 256
#define JWT_TTL (30 * 24 * 3600)

void jwt_init(const char *secret, size_t n);

/* Writes a fresh token for uid into out; returns its length. */
size_t jwt_sign(char out[JWT_MAX], int64_t uid, int64_t now);

/* True if tok is valid at time now (Unix seconds); sets *uid. Uses the arena for scratch. */
bool jwt_verify(struct arena *a, const char *tok, size_t n, double now, int64_t *uid);
