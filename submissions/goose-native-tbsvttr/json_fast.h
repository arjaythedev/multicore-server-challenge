#ifndef GOOSE_JSON_FAST_H
#define GOOSE_JSON_FAST_H

#include <stdint.h>
#include "goose.h"

/* Borrowed u8[:] FFI layout from our twelve-dollar-server-challenge PR #143.
   Goose owns its builders and all application-level JSON structure. */
#pragma pack(push, 1)
typedef struct { const uint8_t *data; int64_t len; } bytes;
typedef struct { uint8_t *data; int64_t len; } mutable_bytes;
#pragma pack(pop)

int64_t json_plain_prefix(bytes text);
void json_append_string(bytes text, gs_rref output);
int32_t native_hmac_sha256(bytes secret, bytes message, mutable_bytes digest);

#endif
