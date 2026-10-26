#include "json_in.h"

#define MAX_DEPTH 64

struct parser {
    const char *p, *end;
    struct arena *a;
    int depth;
};

static void skip_ws(struct parser *ps) {
    while (ps->p < ps->end && (*ps->p == ' ' || *ps->p == '\n' || *ps->p == '\r' || *ps->p == '\t')) ps->p++;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Four hex digits at p, or -1. */
static int32_t hex4(const char *p) {
    int32_t v = 0;
    for (int i = 0; i < 4; i++) {
        int h = hexval(p[i]);
        if (h < 0) return -1;
        v = v << 4 | h;
    }
    return v;
}

static char *put_utf8(char *d, uint32_t cp) {
    if (cp < 0x80) {
        *d++ = (char)cp;
    } else if (cp < 0x800) {
        *d++ = (char)(0xc0 | cp >> 6);
        *d++ = (char)(0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
        *d++ = (char)(0xe0 | cp >> 12);
        *d++ = (char)(0x80 | (cp >> 6 & 0x3f));
        *d++ = (char)(0x80 | (cp & 0x3f));
    } else {
        *d++ = (char)(0xf0 | cp >> 18);
        *d++ = (char)(0x80 | (cp >> 12 & 0x3f));
        *d++ = (char)(0x80 | (cp >> 6 & 0x3f));
        *d++ = (char)(0x80 | (cp & 0x3f));
    }
    return d;
}

/* Length of the valid UTF-8 sequence at s (s < end, *s >= 0x80), or 0 if it is invalid. */
static size_t utf8_seq(const uint8_t *s, const uint8_t *end) {
    uint8_t c = s[0];
    size_t n;
    uint8_t lo = 0x80, hi = 0xbf;  /* range of the second byte */
    if (c >= 0xc2 && c <= 0xdf) n = 2;
    else if (c >= 0xe0 && c <= 0xef) {
        n = 3;
        if (c == 0xe0) lo = 0xa0;
        if (c == 0xed) hi = 0x9f;   /* no surrogates */
    } else if (c >= 0xf0 && c <= 0xf4) {
        n = 4;
        if (c == 0xf0) lo = 0x90;
        if (c == 0xf4) hi = 0x8f;   /* nothing above U+10FFFF */
    } else return 0;
    if ((size_t)(end - s) < n || s[1] < lo || s[1] > hi) return 0;
    for (size_t i = 2; i < n; i++)
        if (s[i] < 0x80 || s[i] > 0xbf) return 0;
    return n;
}

/* Parses the string starting after its opening quote. */
static bool parse_string(struct parser *ps, const char **out, uint32_t *outlen, uint8_t *flags) {
    const char *start = ps->p, *q = ps->p;
    bool simple = true;

    /* Find the closing quote, noting whether the string needs decoding. */
    for (;;) {
        if (q >= ps->end) return false;
        uint8_t c = (uint8_t)*q;
        if (c == '"') break;
        if (c < 0x20) return false;
        if (c == '\\') {
            simple = false;
            if (q + 1 >= ps->end) return false;
            q += 2;
            continue;
        }
        if (c >= 0x80) simple = false;
        q++;
    }
    ps->p = q + 1;
    if (q - start > UINT32_MAX / 3) return false;
    if (simple) {
        *out = start;
        *outlen = (uint32_t)(q - start);
        return true;
    }

    /* Each input byte becomes at most 3 output bytes (an invalid byte becomes U+FFFD). */
    char *buf = arena_alloc(ps->a, (size_t)(q - start) * 3 + 1), *d = buf;
    const char *s = start;
    while (s < q) {
        uint8_t c = (uint8_t)*s;
        if (c == '\\') {
            char e = s[1];
            s += 2;
            switch (e) {
            case '"': *d++ = '"'; break;
            case '\\': *d++ = '\\'; break;
            case '/': *d++ = '/'; break;
            case 'b': *d++ = '\b'; break;
            case 'f': *d++ = '\f'; break;
            case 'n': *d++ = '\n'; break;
            case 'r': *d++ = '\r'; break;
            case 't': *d++ = '\t'; break;
            case 'u': {
                if (q - s < 4) return false;
                int32_t cp = hex4(s);
                if (cp < 0) return false;
                s += 4;
                if (cp >= 0xd800 && cp < 0xe000) {
                    int32_t lo2 = -1;
                    if (cp < 0xdc00 && q - s >= 6 && s[0] == '\\' && s[1] == 'u') lo2 = hex4(s + 2);
                    if (lo2 >= 0xdc00 && lo2 < 0xe000) {
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo2 - 0xdc00);
                        s += 6;
                    } else {
                        cp = 0xfffd;  /* an unpaired surrogate; the next escape is decoded on its own */
                    }
                }
                if (cp == 0) *flags |= JF_NUL;
                d = put_utf8(d, (uint32_t)cp);
                break;
            }
            default:
                return false;
            }
        } else if (c < 0x80) {
            *d++ = (char)c;
            s++;
        } else {
            size_t n = utf8_seq((const uint8_t *)s, (const uint8_t *)q);
            if (n) {
                memcpy(d, s, n);
                d += n, s += n;
            } else {
                d = put_utf8(d, 0xfffd);
                s++;
            }
        }
    }
    *out = buf;
    *outlen = (uint32_t)(d - buf);
    return true;
}

static bool parse_number(struct parser *ps, struct jval *v) {
    const char *s = ps->p, *e = ps->end, *p = s;
    if (p < e && *p == '-') p++;
    if (p >= e) return false;
    if (*p == '0') p++;
    else if (*p >= '1' && *p <= '9') while (p < e && *p >= '0' && *p <= '9') p++;
    else return false;
    if (p < e && *p == '.') {
        p++;
        if (p >= e || *p < '0' || *p > '9') return false;
        while (p < e && *p >= '0' && *p <= '9') p++;
    }
    if (p < e && (*p == 'e' || *p == 'E')) {
        p++;
        if (p < e && (*p == '+' || *p == '-')) p++;
        if (p >= e || *p < '0' || *p > '9') return false;
        while (p < e && *p >= '0' && *p <= '9') p++;
    }
    v->type = J_NUM;
    v->s = s;
    v->len = (uint32_t)(p - s);
    ps->p = p;
    return true;
}

static bool literal(struct parser *ps, const char *word, size_t n) {
    if ((size_t)(ps->end - ps->p) < n || memcmp(ps->p, word, n) != 0) return false;
    ps->p += n;
    return true;
}

static struct jval *parse_value(struct parser *ps);

static bool parse_members(struct parser *ps, struct jval *v, bool object) {
    char close = object ? '}' : ']';
    struct jval **tail = &v->child;
    skip_ws(ps);
    if (ps->p < ps->end && *ps->p == close) {
        ps->p++;
        return true;
    }
    for (;;) {
        const char *key = NULL;
        uint32_t klen = 0;
        if (object) {
            uint8_t kflags = 0;
            if (ps->p >= ps->end || *ps->p != '"') return false;
            ps->p++;
            if (!parse_string(ps, &key, &klen, &kflags)) return false;
            skip_ws(ps);
            if (ps->p >= ps->end || *ps->p != ':') return false;
            ps->p++;
        }
        struct jval *c = parse_value(ps);
        if (!c) return false;
        c->key = key;
        c->klen = klen;
        *tail = c;
        tail = &c->next;
        v->len++;
        skip_ws(ps);
        if (ps->p >= ps->end) return false;
        char ch = *ps->p++;
        if (ch == close) return true;
        if (ch != ',') return false;
        skip_ws(ps);
    }
}

static struct jval *parse_value(struct parser *ps) {
    skip_ws(ps);
    if (ps->p >= ps->end) return NULL;
    struct jval *v = arena_alloc(ps->a, sizeof *v);
    memset(v, 0, sizeof *v);
    char c = *ps->p;
    switch (c) {
    case '{':
    case '[':
        if (++ps->depth > MAX_DEPTH) return NULL;
        ps->p++;
        v->type = c == '{' ? J_OBJ : J_ARR;
        if (!parse_members(ps, v, c == '{')) return NULL;
        ps->depth--;
        return v;
    case '"':
        ps->p++;
        v->type = J_STR;
        return parse_string(ps, &v->s, &v->len, &v->flags) ? v : NULL;
    case 't':
        v->type = J_TRUE;
        return literal(ps, LIT("true")) ? v : NULL;
    case 'f':
        v->type = J_FALSE;
        return literal(ps, LIT("false")) ? v : NULL;
    case 'n':
        v->type = J_NULL;
        return literal(ps, LIT("null")) ? v : NULL;
    default:
        return parse_number(ps, v) ? v : NULL;
    }
}

struct jval *json_parse(struct arena *a, const char *p, size_t n) {
    struct parser ps = {.p = p, .end = p + n, .a = a};
    struct jval *v = parse_value(&ps);
    if (!v) return NULL;
    skip_ws(&ps);
    return ps.p == ps.end ? v : NULL;
}

const struct jval *json_get(const struct jval *obj, const char *key, size_t klen) {
    const struct jval *found = NULL;
    if (!obj || obj->type != J_OBJ) return NULL;
    for (const struct jval *c = obj->child; c; c = c->next)
        if (c->klen == klen && memcmp(c->key, key, klen) == 0) found = c;
    return found;
}

double json_num(const struct jval *v) {
    /* The raw text is not NUL-terminated, so strtod gets a copy. */
    char tmp[64], *s = v->len < sizeof tmp ? tmp : xmalloc(v->len + 1);
    memcpy(s, v->s, v->len);
    s[v->len] = 0;
    double d = strtod(s, NULL);
    if (s != tmp) free(s);
    return d;
}
