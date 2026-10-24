// Strict RFC 8259 JSON parser allocating every node and unescaped string slice out of the request's bump arena.
#include "conduit.h"

typedef struct {
    arena_t *a;
    const char *s;
    size_t n, i;
    int depth;
} jp_t;

static void skip_ws(jp_t *p) {
    while (p->i < p->n) {
        char c = p->s[p->i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->i++;
        else break;
    }
}

static int hex4(const char *s) {
    int v = 0;
    for (int i = 0; i < 4; i++) {
        char c = s[i];
        int d = (c >= '0' && c <= '9') ? c - '0' : (c >= 'a' && c <= 'f') ? c - 'a' + 10 : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
        if (d < 0) return -1;
        v = (v << 4) | d;
    }
    return v;
}

static size_t put_utf8(char *o, uint32_t cp) {
    if (cp <= 0x7f) { o[0] = (char)cp; return 1; }
    if (cp <= 0x7ff) { o[0] = (char)(0xc0 | (cp >> 6)); o[1] = (char)(0x80 | (cp & 0x3f)); return 2; }
    if (cp <= 0xffff) {
        o[0] = (char)(0xe0 | (cp >> 12));
        o[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
        o[2] = (char)(0x80 | (cp & 0x3f));
        return 3;
    }
    o[0] = (char)(0xf0 | (cp >> 18));
    o[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
    o[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
    o[3] = (char)(0x80 | (cp & 0x3f));
    return 4;
}

static bool parse_str_raw(jp_t *p, str_t *out) {
    if (p->i >= p->n || p->s[p->i] != '"') return false;
    p->i++;
    size_t start = p->i;
    bool has_esc = false;
    while (p->i < p->n) {
        unsigned char c = (unsigned char)p->s[p->i];
        if (c == '"') {
            if (!has_esc) {
                *out = (str_t){p->s + start, p->i - start};
                p->i++;
                return true;
            }
            break;
        }
        if (c < 0x20) return false;
        if (c == '\\') {
            has_esc = true;
            p->i++;
            if (p->i >= p->n) return false;
        }
        p->i++;
    }
    if (p->i >= p->n) return false;

    size_t max_len = p->i - start;
    char *dst = arena_alloc(p->a, max_len + 1);
    size_t j = 0;
    p->i = start;
    while (p->i < p->n) {
        unsigned char c = (unsigned char)p->s[p->i++];
        if (c == '"') {
            dst[j] = 0;
            *out = (str_t){dst, j};
            return true;
        }
        if (c < 0x20) return false;
        if (c != '\\') {
            dst[j++] = (char)c;
            continue;
        }
        if (p->i >= p->n) return false;
        char e = p->s[p->i++];
        switch (e) {
        case '"': dst[j++] = '"'; break;
        case '\\': dst[j++] = '\\'; break;
        case '/': dst[j++] = '/'; break;
        case 'b': dst[j++] = '\b'; break;
        case 'f': dst[j++] = '\f'; break;
        case 'n': dst[j++] = '\n'; break;
        case 'r': dst[j++] = '\r'; break;
        case 't': dst[j++] = '\t'; break;
        case 'u': {
            if (p->i + 4 > p->n) return false;
            int u1 = hex4(p->s + p->i);
            if (u1 < 0) return false;
            p->i += 4;
            uint32_t cp = (uint32_t)u1;
            if (u1 >= 0xd800 && u1 <= 0xdbff) {
                if (p->i + 6 > p->n || p->s[p->i] != '\\' || p->s[p->i + 1] != 'u') return false;
                int u2 = hex4(p->s + p->i + 2);
                if (u2 < 0xdc00 || u2 > 0xdfff) return false;
                p->i += 6;
                cp = 0x10000 + (((uint32_t)(u1 - 0xd800) << 10) | (uint32_t)(u2 - 0xdc00));
            } else if (u1 >= 0xdc00 && u1 <= 0xdfff) {
                return false;
            }
            j += put_utf8(dst + j, cp);
            break;
        }
        default: return false;
        }
    }
    return false;
}

static jv_t *parse_val(jp_t *p);

static jv_t *alloc_jv(jp_t *p, uint8_t type) {
    jv_t *v = arena_alloc(p->a, sizeof(jv_t));
    memset(v, 0, sizeof(jv_t));
    v->type = type;
    return v;
}

static jv_t *parse_num(jp_t *p) {
    size_t start = p->i;
    if (p->s[p->i] == '-') p->i++;
    if (p->i >= p->n) return NULL;
    if (p->s[p->i] == '0') {
        p->i++;
        if (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') return NULL;
    } else if (p->s[p->i] >= '1' && p->s[p->i] <= '9') {
        while (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') p->i++;
    } else {
        return NULL;
    }
    if (p->i < p->n && p->s[p->i] == '.') {
        p->i++;
        if (p->i >= p->n || p->s[p->i] < '0' || p->s[p->i] > '9') return NULL;
        while (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') p->i++;
    }
    if (p->i < p->n && (p->s[p->i] == 'e' || p->s[p->i] == 'E')) {
        p->i++;
        if (p->i < p->n && (p->s[p->i] == '+' || p->s[p->i] == '-')) p->i++;
        if (p->i >= p->n || p->s[p->i] < '0' || p->s[p->i] > '9') return NULL;
        while (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') p->i++;
    }
    size_t len = p->i - start;
    char tmp[64];
    if (len >= sizeof(tmp)) return NULL;
    memcpy(tmp, p->s + start, len);
    tmp[len] = 0;
    char *end = NULL;
    double d = strtod(tmp, &end);
    if (end != tmp + len) return NULL;
    jv_t *v = alloc_jv(p, J_NUM);
    v->num = d;
    v->raw = (str_t){p->s + start, len};
    return v;
}

static jv_t *parse_arr(jp_t *p) {
    if (++p->depth > 32) return NULL;
    p->i++;
    jv_t *arr = alloc_jv(p, J_ARR), **tail = &arr->child;
    skip_ws(p);
    if (p->i < p->n && p->s[p->i] == ']') { p->i++; p->depth--; return arr; }
    for (;;) {
        jv_t *el = parse_val(p);
        if (!el) return NULL;
        *tail = el;
        tail = &el->next;
        skip_ws(p);
        if (p->i >= p->n) return NULL;
        if (p->s[p->i] == ']') { p->i++; p->depth--; return arr; }
        if (p->s[p->i] != ',') return NULL;
        p->i++;
    }
}

static jv_t *parse_obj(jp_t *p) {
    if (++p->depth > 32) return NULL;
    p->i++;
    jv_t *obj = alloc_jv(p, J_OBJ), **tail = &obj->child;
    skip_ws(p);
    if (p->i < p->n && p->s[p->i] == '}') { p->i++; p->depth--; return obj; }
    for (;;) {
        skip_ws(p);
        str_t key;
        if (!parse_str_raw(p, &key)) return NULL;
        skip_ws(p);
        if (p->i >= p->n || p->s[p->i] != ':') return NULL;
        p->i++;
        jv_t *val = parse_val(p);
        if (!val) return NULL;
        val->key = key;
        *tail = val;
        tail = &val->next;
        skip_ws(p);
        if (p->i >= p->n) return NULL;
        if (p->s[p->i] == '}') { p->i++; p->depth--; return obj; }
        if (p->s[p->i] != ',') return NULL;
        p->i++;
    }
}

static jv_t *parse_val(jp_t *p) {
    skip_ws(p);
    if (p->i >= p->n) return NULL;
    char c = p->s[p->i];
    if (c == '"') {
        jv_t *v = alloc_jv(p, J_STR);
        return parse_str_raw(p, &v->s) ? v : NULL;
    }
    if (c == '{') return parse_obj(p);
    if (c == '[') return parse_arr(p);
    if (c == 't' && p->i + 4 <= p->n && memcmp(p->s + p->i, "true", 4) == 0) {
        p->i += 4;
        jv_t *v = alloc_jv(p, J_BOOL);
        v->b = true;
        return v;
    }
    if (c == 'f' && p->i + 5 <= p->n && memcmp(p->s + p->i, "false", 5) == 0) {
        p->i += 5;
        return alloc_jv(p, J_BOOL);
    }
    if (c == 'n' && p->i + 4 <= p->n && memcmp(p->s + p->i, "null", 4) == 0) {
        p->i += 4;
        return alloc_jv(p, J_NULL);
    }
    if (c == '-' || (c >= '0' && c <= '9')) return parse_num(p);
    return NULL;
}

jv_t *json_parse(arena_t *a, const char *src, size_t len) {
    jp_t p = {a, src, len, 0, 0};
    jv_t *v = parse_val(&p);
    if (!v) return NULL;
    skip_ws(&p);
    return p.i == p.n ? v : NULL;
}

jv_t *json_get(const jv_t *obj, const char *key) {
    if (!obj || obj->type != J_OBJ) return NULL;
    size_t n = strlen(key);
    jv_t *found = NULL;
    for (jv_t *c = obj->child; c; c = c->next)
        if (c->key.n == n && memcmp(c->key.p, key, n) == 0) found = c;
    return found;
}
