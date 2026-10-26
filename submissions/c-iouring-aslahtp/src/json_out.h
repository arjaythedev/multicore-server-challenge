/* JSON writing: quoted strings and timestamps, straight from Postgres binary values. */
#pragma once
#include "buf.h"

/* A quoted, escaped JSON string. The input is valid UTF-8 (it comes from Postgres or from json_parse). */
void json_str(struct buf *b, const char *s, size_t n);
#define json_strl(b, lit) json_str((b), (lit), sizeof(lit) - 1)

/* Postgres timestamptz (binary: microseconds since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ", quoted,
 * milliseconds truncated. fmt_ts writes the 24 characters without quotes. */
#define TS_LEN 24
void fmt_ts(char out[TS_LEN], int64_t pg_us);
void json_ts(struct buf *b, int64_t pg_us);

/* Microseconds between 1970-01-01 and Postgres's epoch 2000-01-01. */
#define PG_EPOCH_UNIX_US INT64_C(946684800000000)
