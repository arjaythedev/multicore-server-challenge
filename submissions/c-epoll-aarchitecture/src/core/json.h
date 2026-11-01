#ifndef CORE_JSON_H
#define CORE_JSON_H

#include <stddef.h>

#include "core/buf.h"

/* RFC 8259 parser into a small tree + string writer. keeps the distinctions
 * the API needs: absent vs null vs "", int vs fraction/exponent, malformed vs
 * other shape. strings unescaped at parse time, NUL-terminated (U+0000
 * rejected); depth bounded */

typedef enum {
    JSON_NULL,
    JSON_FALSE,
    JSON_TRUE,
    JSON_NUM,
    JSON_STR,
    JSON_ARR,
    JSON_OBJ,
} json_kind;

typedef struct json_node {
    json_kind kind;
    long long num;              // JSON_NUM, when is_int
    int is_int;                 // no '.' / exponent
    const char *str;            // JSON_STR: unescaped, NUL-terminated
    unsigned nchild;            // ARR + OBJ
    struct json_node **child;   // ARR values / OBJ values
    const char **keys;          // OBJ member names, aligned with child
} json_node;

/* NULL on malformed input; *err = static description */
json_node *json_parse(const char *data, size_t len, const char **err);
void json_free(json_node *n);

const json_node *json_get(const json_node *obj, const char *key);
const char *json_str(const json_node *v);

/* quoted JSON string; bytes >= 0x20 pass (UTF-8 not validated, as in the
 * parser); quotes, backslashes, controls escape */
void json_quote(buf *out, const char *s);
void json_quote_bytes(buf *out, const char *s, size_t n);

#endif
