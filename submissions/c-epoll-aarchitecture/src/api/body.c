#include "api/api.h"

#include <string.h>

// body accessors expose 3 states: ABSENT (incl json null), OK, INVALID

const json_node *body_object(const api_request *r, const char *wrapper) {
    if (!r->body || r->body->kind != JSON_OBJ) return NULL;
    const json_node *value = json_get(r->body, wrapper);
    return value && value->kind == JSON_OBJ ? value : NULL;
}

static field_result read_string(const json_node *obj, const char *key,
                                const char **out, bool allow_empty) {
    const json_node *value = json_get(obj, key);
    if (!value || value->kind == JSON_NULL) return FIELD_ABSENT;
    if (value->kind != JSON_STR) return FIELD_INVALID;
    if (!allow_empty && value->str[0] == '\0') return FIELD_INVALID;
    *out = value->str;
    return FIELD_OK;
}

field_result body_string(const json_node *obj, const char *key,
                         const char **out) {
    return read_string(obj, key, out, false);
}

field_result body_string_allow_empty(const json_node *obj, const char *key,
                                     const char **out) {
    return read_string(obj, key, out, true);
}

// always quote: unambiguous for any tag chars
static void pack_element(buf *out, const char *s) {
    buf_putc(out, '"');
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') buf_putc(out, '\\');
        buf_putc(out, *s);
    }
    buf_putc(out, '"');
}

field_result body_text_array(api_request *r, const json_node *value,
                             char **out) {
    *out = NULL;
    if (!value || value->kind == JSON_NULL) return FIELD_ABSENT;
    if (value->kind != JSON_ARR) return FIELD_INVALID;

    buf literal;
    buf_init(&literal);
    buf_putc(&literal, '{');
    for (unsigned i = 0; i < value->nchild; i++) {
        const json_node *element = value->child[i];
        if (element->kind != JSON_STR || element->str[0] == '\0') {
            buf_free(&literal);
            return FIELD_INVALID;
        }
        if (i) buf_putc(&literal, ',');
        pack_element(&literal, element->str);
    }
    buf_putc(&literal, '}');

    *out = arena_str(&r->arena, literal.data, literal.len);
    buf_free(&literal);
    return FIELD_OK;
}
