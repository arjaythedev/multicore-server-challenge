/* Strict JSON reader for request bodies and JWT segments. Builds a small tree in a scratch arena.
 *
 * It follows what the Go reference server's encoding/json accepts, so the same bodies pass and fail: RFC 8259
 * grammar, one value with only whitespace after it, invalid UTF-8 and unpaired surrogates replaced by U+FFFD,
 * duplicate keys resolved to the last one. A string that decodes to a NUL byte is flagged (JF_NUL): Postgres
 * text cannot hold it, so handlers reject such fields with 422 instead of failing a whole write batch. */
#pragma once
#include "arena.h"

enum jtype { J_NULL, J_FALSE, J_TRUE, J_NUM, J_STR, J_ARR, J_OBJ };

#define JF_NUL 1

struct jval {
    uint8_t type, flags;
    uint32_t len;        /* J_STR: decoded bytes; J_NUM: raw characters; J_ARR/J_OBJ: number of children */
    const char *s;       /* J_STR: decoded bytes (not NUL-terminated); J_NUM: the raw text */
    const char *key;     /* set on object members */
    uint32_t klen;
    struct jval *child;  /* J_ARR/J_OBJ: first child */
    struct jval *next;   /* next sibling */
};

/* NULL if the input is not one well-formed JSON value. */
struct jval *json_parse(struct arena *a, const char *p, size_t n);

/* Object member by key (the last one, if repeated), or NULL. */
const struct jval *json_get(const struct jval *obj, const char *key, size_t klen);
#define json_getl(obj, lit) json_get((obj), (lit), sizeof(lit) - 1)

/* A J_NUM's value as a double (JWT times). */
double json_num(const struct jval *v);
