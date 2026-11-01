#include "core/json.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "util.h"

/* recursive descent. parse_* free their partial node on failure, so json_parse
 * owns one tree throughout */

typedef struct cursor {
    const char *p;
    const char *end;
    const char *error;
} cursor;

static json_node *parse_value(cursor *c, unsigned depth);

static void fail(cursor *c, const char *message) {
    if (!c->error) c->error = message;
}

static void skip_ws(cursor *c) {
    while (c->p < c->end) {
        char ch = *c->p;
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') c->p++;
        else break;
    }
}

static json_node *new_node(json_kind kind) {
    json_node *n = xcalloc(1, sizeof *n);
    n->kind = kind;
    return n;
}

static int hex_digit(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

static bool read_hex4(cursor *c, const char **pp, unsigned *out) {
    const char *p = *pp;
    if (c->end - p < 4) return false;
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        int d = hex_digit(p[i]);
        if (d < 0) return false;
        v = v * 16 + (unsigned)d;
    }
    *pp = p + 4;
    *out = v;
    return true;
}

/* inside of a quoted string, escapes included -> malloc'd unescaped copy */
static char *decode_string(cursor *c, const char *start, const char *end) {
    char *out = xmalloc((size_t)(end - start) + 1);
    char *o = out;
    const char *p = start;

    while (p < end) {
        unsigned char ch = (unsigned char)*p++;
        if (ch != '\\') {
            *o++ = (char)ch;
            continue;
        }
        if (p >= end) {
            fail(c, "string ends in a backslash");
            free(out);
            return NULL;
        }
        char esc = *p++;
        switch (esc) {
        case '"':  *o++ = '"';  break;
        case '\\': *o++ = '\\'; break;
        case '/':  *o++ = '/';  break;
        case 'b':  *o++ = '\b'; break;
        case 'f':  *o++ = '\f'; break;
        case 'n':  *o++ = '\n'; break;
        case 'r':  *o++ = '\r'; break;
        case 't':  *o++ = '\t'; break;
        case 'u': {
            unsigned code;
            if (!read_hex4(c, &p, &code)) {
                fail(c, "bad \\u escape");
                free(out);
                return NULL;
            }
            if (code >= 0xD800 && code <= 0xDBFF) {
                if (c->end - p < 2 || p[0] != '\\' || p[1] != 'u') {
                    fail(c, "unpaired high surrogate");
                    free(out);
                    return NULL;
                }
                p += 2;
                unsigned low;
                if (!read_hex4(c, &p, &low)) {
                    fail(c, "bad \\u escape");
                    free(out);
                    return NULL;
                }
                if (low < 0xDC00 || low > 0xDFFF) {
                    fail(c, "unpaired high surrogate");
                    free(out);
                    return NULL;
                }
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
            } else if (code >= 0xDC00 && code <= 0xDFFF) {
                fail(c, "unpaired low surrogate");
                free(out);
                return NULL;
            }
            if (code == 0) {
                /* rest of the process (and pg text params) wants NUL-terminated
                 * strings */
                fail(c, "NUL character in string");
                free(out);
                return NULL;
            }
            if (code < 0x80) {
                *o++ = (char)code;
            } else if (code < 0x800) {
                *o++ = (char)(0xC0 | (code >> 6));
                *o++ = (char)(0x80 | (code & 0x3F));
            } else if (code < 0x10000) {
                *o++ = (char)(0xE0 | (code >> 12));
                *o++ = (char)(0x80 | ((code >> 6) & 0x3F));
                *o++ = (char)(0x80 | (code & 0x3F));
            } else {
                *o++ = (char)(0xF0 | (code >> 18));
                *o++ = (char)(0x80 | ((code >> 12) & 0x3F));
                *o++ = (char)(0x80 | ((code >> 6) & 0x3F));
                *o++ = (char)(0x80 | (code & 0x3F));
            }
            break;
        }
        default:
            fail(c, "bad escape");
            free(out);
            return NULL;
        }
    }
    *o = '\0';
    return out;
}

static const char *string_end(cursor *c, const char *start) {
    for (const char *p = start; p < c->end; p++) {
        unsigned char ch = (unsigned char)*p;
        if (ch == '\\') {
            p++;
            continue;
        }
        if (ch == '"') return p;
        if (ch < 0x20) {
            fail(c, "raw control byte in string");
            return NULL;
        }
    }
    fail(c, "unterminated string");
    return NULL;
}

/* c->p on the opening quote; advances past the closing one */
static char *parse_string_value(cursor *c) {
    const char *end = string_end(c, c->p + 1);
    if (!end) return NULL;
    char *s = decode_string(c, c->p + 1, end);
    if (!s) return NULL;
    c->p = end + 1;
    return s;
}

static json_node *parse_string(cursor *c) {
    char *s = parse_string_value(c);
    if (!s) return NULL;
    json_node *n = new_node(JSON_STR);
    n->str = s;
    return n;
}

static json_node *parse_number(cursor *c) {
    const char *start = c->p;
    if (c->p < c->end && *c->p == '-') c->p++;

    const char *digits = c->p;
    while (c->p < c->end && *c->p >= '0' && *c->p <= '9') c->p++;
    if (c->p == digits) {
        fail(c, "number without digits");
        return NULL;
    }

    bool is_int = true;
    if (c->p < c->end && *c->p == '.') {
        is_int = false;
        c->p++;
        const char *frac = c->p;
        while (c->p < c->end && *c->p >= '0' && *c->p <= '9') c->p++;
        if (c->p == frac) {
            fail(c, "fraction without digits");
            return NULL;
        }
    }
    if (c->p < c->end && (*c->p == 'e' || *c->p == 'E')) {
        is_int = false;
        c->p++;
        if (c->p < c->end && (*c->p == '+' || *c->p == '-')) c->p++;
        const char *exponent = c->p;
        while (c->p < c->end && *c->p >= '0' && *c->p <= '9') c->p++;
        if (c->p == exponent) {
            fail(c, "exponent without digits");
            return NULL;
        }
    }

    json_node *n = new_node(JSON_NUM);
    n->is_int = is_int;
    if (is_int) {
        /* strtoll wants a C string; the document is a byte slice */
        char tmp[32];
        size_t len = (size_t)(c->p - start);
        if (len >= sizeof tmp) len = sizeof tmp - 1;
        memcpy(tmp, start, len);
        tmp[len] = '\0';
        n->num = strtoll(tmp, NULL, 10);
    }
    return n;
}

static json_node *parse_array(cursor *c, unsigned depth) {
    json_node *n = new_node(JSON_ARR);
    c->p++;                     // '['
    skip_ws(c);
    if (c->p < c->end && *c->p == ']') {
        c->p++;
        return n;
    }

    size_t cap = 4;
    n->child = xmalloc(cap * sizeof *n->child);
    for (;;) {
        json_node *value = parse_value(c, depth + 1);
        if (!value) {
            json_free(n);
            return NULL;
        }
        if (n->nchild == cap) {
            cap *= 2;
            n->child = xrealloc(n->child, cap * sizeof *n->child);
        }
        n->child[n->nchild++] = value;

        skip_ws(c);
        if (c->p < c->end && *c->p == ',') {
            c->p++;
            continue;
        }
        if (c->p < c->end && *c->p == ']') {
            c->p++;
            return n;
        }
        fail(c, "array member not followed by ',' or ']'");
        json_free(n);
        return NULL;
    }
}

static json_node *parse_object(cursor *c, unsigned depth) {
    json_node *n = new_node(JSON_OBJ);
    c->p++;                     // '{'
    skip_ws(c);
    if (c->p < c->end && *c->p == '}') {
        c->p++;
        return n;
    }

    size_t cap = 6;
    n->child = xmalloc(cap * sizeof *n->child);
    n->keys = xmalloc(cap * sizeof *n->keys);
    for (;;) {
        skip_ws(c);
        if (c->p >= c->end || *c->p != '"') {
            fail(c, "object member without a name");
            json_free(n);
            return NULL;
        }
        char *key = parse_string_value(c);
        if (!key) {
            json_free(n);
            return NULL;
        }
        skip_ws(c);
        if (c->p >= c->end || *c->p != ':') {
            fail(c, "object member without ':'");
            free(key);
            json_free(n);
            return NULL;
        }
        c->p++;
        json_node *value = parse_value(c, depth + 1);
        if (!value) {
            free(key);
            json_free(n);
            return NULL;
        }
        if (n->nchild == cap) {
            cap *= 2;
            n->child = xrealloc(n->child, cap * sizeof *n->child);
            n->keys = xrealloc(n->keys, cap * sizeof *n->keys);
        }
        n->keys[n->nchild] = key;
        n->child[n->nchild] = value;
        n->nchild++;

        skip_ws(c);
        if (c->p < c->end && *c->p == ',') {
            c->p++;
            continue;
        }
        if (c->p < c->end && *c->p == '}') {
            c->p++;
            return n;
        }
        fail(c, "object member not followed by ',' or '}'");
        json_free(n);
        return NULL;
    }
}

static json_node *parse_value(cursor *c, unsigned depth) {
    if (depth > JSON_MAX_DEPTH) {
        fail(c, "document nested too deeply");
        return NULL;
    }
    skip_ws(c);
    if (c->p >= c->end) {
        fail(c, "unexpected end of document");
        return NULL;
    }
    switch (*c->p) {
    case '{': return parse_object(c, depth + 1);
    case '[': return parse_array(c, depth + 1);
    case '"': return parse_string(c);
    case 't':
        if (c->end - c->p >= 4 && memcmp(c->p, "true", 4) == 0) {
            c->p += 4;
            return new_node(JSON_TRUE);
        }
        fail(c, "bad literal");
        return NULL;
    case 'f':
        if (c->end - c->p >= 5 && memcmp(c->p, "false", 5) == 0) {
            c->p += 5;
            return new_node(JSON_FALSE);
        }
        fail(c, "bad literal");
        return NULL;
    case 'n':
        if (c->end - c->p >= 4 && memcmp(c->p, "null", 4) == 0) {
            c->p += 4;
            return new_node(JSON_NULL);
        }
        fail(c, "bad literal");
        return NULL;
    default:
        if (*c->p == '-' || (*c->p >= '0' && *c->p <= '9'))
            return parse_number(c);
        fail(c, "unexpected character");
        return NULL;
    }
}

json_node *json_parse(const char *data, size_t len, const char **err) {
    CHECK(err != NULL, "json_parse: err is required");
    *err = NULL;
    cursor c = { .p = data, .end = data + len, .error = NULL };

    json_node *n = parse_value(&c, 0);
    if (!n) {
        *err = c.error ? c.error : "malformed json";
        return NULL;
    }
    skip_ws(&c);
    if (c.p != c.end) {
        json_free(n);
        *err = "trailing bytes after document";
        return NULL;
    }
    return n;
}

void json_free(json_node *n) {
    if (!n) return;
    if (n->kind == JSON_STR) free((void *)n->str);
    if (n->kind == JSON_OBJ) {
        for (unsigned i = 0; i < n->nchild; i++) free((void *)n->keys[i]);
    }
    for (unsigned i = 0; i < n->nchild; i++) json_free(n->child[i]);
    free(n->child);
    free(n->keys);
    free(n);
}

const json_node *json_get(const json_node *obj, const char *key) {
    if (!obj || obj->kind != JSON_OBJ) return NULL;
    for (unsigned i = 0; i < obj->nchild; i++) {
        if (strcmp(obj->keys[i], key) == 0) return obj->child[i];
    }
    return NULL;
}

const char *json_str(const json_node *v) {
    return v && v->kind == JSON_STR ? v->str : NULL;
}

void json_quote_bytes(buf *out, const char *s, size_t n) {
    static const char HEX[] = "0123456789abcdef";
    buf_putc(out, '"');
    size_t run = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char ch = (unsigned char)s[i];
        if (ch >= 0x20 && ch != '"' && ch != '\\') {
            run++;
            continue;
        }
        if (run) {
            buf_append(out, s + (i - run), run);
            run = 0;
        }
        switch (ch) {
        case '"':  BUF_LIT(out, "\\\""); break;
        case '\\': BUF_LIT(out, "\\\\"); break;
        case '\b': BUF_LIT(out, "\\b");  break;
        case '\f': BUF_LIT(out, "\\f");  break;
        case '\n': BUF_LIT(out, "\\n");  break;
        case '\r': BUF_LIT(out, "\\r");  break;
        case '\t': BUF_LIT(out, "\\t");  break;
        default:
            BUF_LIT(out, "\\u00");
            buf_putc(out, HEX[(ch >> 4) & 0xF]);
            buf_putc(out, HEX[ch & 0xF]);
            break;
        }
    }
    if (run) buf_append(out, s + (n - run), run);
    buf_putc(out, '"');
}

void json_quote(buf *out, const char *s) {
    json_quote_bytes(out, s, strlen(s));
}
