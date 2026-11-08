// A strict JSON parser (RFC 8259, as Go's encoding/json accepts it) into an arena-allocated tree.
#include "conduit.h"

typedef struct { const char *p, *end; arena_t *a; int depth; } jp_t;

static void ws(jp_t *j) {
    while (j->p < j->end && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r')) j->p++;
}

static int hexv(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool hex4(const char *p, uint32_t *v) {
    uint32_t r = 0;
    for (int i = 0; i < 4; i++) {
        int h = hexv(p[i]);
        if (h < 0) return false;
        r = r << 4 | h;
    }
    *v = r;
    return true;
}

static size_t put_utf8(char *o, uint32_t cp) {
    if (cp < 0x80) { o[0] = cp; return 1; }
    if (cp < 0x800) { o[0] = 0xC0 | cp >> 6; o[1] = 0x80 | (cp & 63); return 2; }
    if (cp < 0x10000) { o[0] = 0xE0 | cp >> 12; o[1] = 0x80 | ((cp >> 6) & 63); o[2] = 0x80 | (cp & 63); return 3; }
    o[0] = 0xF0 | cp >> 18; o[1] = 0x80 | ((cp >> 12) & 63); o[2] = 0x80 | ((cp >> 6) & 63); o[3] = 0x80 | (cp & 63);
    return 4;
}

// Length of a valid UTF-8 sequence at p (1..4), or 0 if invalid (Go then substitutes U+FFFD for one byte).
static int utf8_len(const unsigned char *p, const unsigned char *end) {
    unsigned c = p[0];
    if (c < 0x80) return 1;
    int n;
    uint32_t cp, min;
    if ((c & 0xE0) == 0xC0) { n = 2; cp = c & 0x1F; min = 0x80; }
    else if ((c & 0xF0) == 0xE0) { n = 3; cp = c & 0x0F; min = 0x800; }
    else if ((c & 0xF8) == 0xF0) { n = 4; cp = c & 0x07; min = 0x10000; }
    else return 0;
    if (end - p < n) return 0;
    for (int i = 1; i < n; i++) {
        if ((p[i] & 0xC0) != 0x80) return 0;
        cp = cp << 6 | (p[i] & 63);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
    return n;
}

static bool parse_string(jp_t *j, str_t *out) {
    const char *s = ++j->p; // after the opening quote
    bool simple = true;
    const char *p = s;
    while (p < j->end && *p != '"') {
        unsigned char c = *p;
        if (c < 0x20) return false;
        if (c == '\\') { simple = false; p += 2; continue; }
        if (c >= 0x80) {
            int l = utf8_len((const unsigned char *)p, (const unsigned char *)j->end);
            if (!l) { simple = false; l = 1; }
            p += l;
            continue;
        }
        p++;
    }
    if (p >= j->end) return false;
    if (simple) {
        *out = (str_t){s, (size_t)(p - s)};
        j->p = p + 1;
        return true;
    }
    char *o = arena_alloc(j->a, (p - s) * 3 + 4), *o0 = o;
    p = s;
    for (;;) {
        if (p >= j->end) return false;
        unsigned char c = *p;
        if (c == '"') break;
        if (c < 0x20) return false;
        if (c == '\\') {
            if (p + 1 >= j->end) return false;
            char e = p[1];
            p += 2;
            switch (e) {
            case '"': *o++ = '"'; break;
            case '\\': *o++ = '\\'; break;
            case '/': *o++ = '/'; break;
            case 'b': *o++ = '\b'; break;
            case 'f': *o++ = '\f'; break;
            case 'n': *o++ = '\n'; break;
            case 'r': *o++ = '\r'; break;
            case 't': *o++ = '\t'; break;
            case 'u': {
                uint32_t cp;
                if (j->end - p < 4 || !hex4(p, &cp)) return false;
                p += 4;
                if (cp >= 0xD800 && cp < 0xDC00) {
                    uint32_t lo;
                    if (j->end - p >= 6 && p[0] == '\\' && p[1] == 'u' && hex4(p + 2, &lo) && lo >= 0xDC00 && lo < 0xE000) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        p += 6;
                    } else {
                        cp = 0xFFFD;
                    }
                } else if (cp >= 0xDC00 && cp < 0xE000) {
                    cp = 0xFFFD;
                }
                o += put_utf8(o, cp);
                break;
            }
            default: return false;
            }
            continue;
        }
        if (c >= 0x80) {
            int l = utf8_len((const unsigned char *)p, (const unsigned char *)j->end);
            if (!l) { o += put_utf8(o, 0xFFFD); p++; }
            else { memcpy(o, p, l); o += l; p += l; }
            continue;
        }
        *o++ = c;
        p++;
    }
    *out = (str_t){o0, (size_t)(o - o0)};
    j->p = p + 1;
    return true;
}

static bool parse_number(jp_t *j, str_t *out) {
    const char *s = j->p, *p = s, *e = j->end;
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
    *out = (str_t){s, (size_t)(p - s)};
    j->p = p;
    return true;
}

static jv_t *parse_value(jp_t *j);

static bool lit(jp_t *j, const char *w, size_t n) {
    if ((size_t)(j->end - j->p) < n || memcmp(j->p, w, n) != 0) return false;
    j->p += n;
    return true;
}

static jv_t *parse_value(jp_t *j) {
    ws(j);
    if (j->p >= j->end) return NULL;
    jv_t *v = arena_alloc(j->a, sizeof *v);
    memset(v, 0, sizeof *v);
    switch (*j->p) {
    case '{': {
        if (++j->depth > 1000) return NULL;
        v->type = J_OBJ;
        j->p++;
        ws(j);
        if (j->p < j->end && *j->p == '}') { j->p++; j->depth--; return v; }
        jv_t **tail = &v->child;
        for (;;) {
            ws(j);
            if (j->p >= j->end || *j->p != '"') return NULL;
            str_t key;
            if (!parse_string(j, &key)) return NULL;
            ws(j);
            if (j->p >= j->end || *j->p != ':') return NULL;
            j->p++;
            jv_t *m = parse_value(j);
            if (!m) return NULL;
            m->key = key;
            *tail = m;
            tail = &m->next;
            ws(j);
            if (j->p >= j->end) return NULL;
            if (*j->p == ',') { j->p++; continue; }
            if (*j->p == '}') { j->p++; break; }
            return NULL;
        }
        j->depth--;
        return v;
    }
    case '[': {
        if (++j->depth > 1000) return NULL;
        v->type = J_ARR;
        j->p++;
        ws(j);
        if (j->p < j->end && *j->p == ']') { j->p++; j->depth--; return v; }
        jv_t **tail = &v->child;
        for (;;) {
            jv_t *m = parse_value(j);
            if (!m) return NULL;
            *tail = m;
            tail = &m->next;
            ws(j);
            if (j->p >= j->end) return NULL;
            if (*j->p == ',') { j->p++; continue; }
            if (*j->p == ']') { j->p++; break; }
            return NULL;
        }
        j->depth--;
        return v;
    }
    case '"':
        v->type = J_STR;
        return parse_string(j, &v->s) ? v : NULL;
    case 't': v->type = J_TRUE; return lit(j, "true", 4) ? v : NULL;
    case 'f': v->type = J_FALSE; return lit(j, "false", 5) ? v : NULL;
    case 'n': v->type = J_NULL; return lit(j, "null", 4) ? v : NULL;
    default:
        v->type = J_NUM;
        return parse_number(j, &v->s) ? v : NULL;
    }
}

jv_t *json_parse(arena_t *a, const char *p, size_t n) {
    jp_t j = {p, p + n, a, 0};
    jv_t *v = parse_value(&j);
    if (!v) return NULL;
    ws(&j);
    return j.p == j.end ? v : NULL;
}

jv_t *json_get(const jv_t *obj, const char *key) {
    if (!obj || obj->type != J_OBJ) return NULL;
    size_t n = strlen(key);
    jv_t *found = NULL;
    for (jv_t *m = obj->child; m; m = m->next)
        if (m->key.n == n && memcmp(m->key.p, key, n) == 0) found = m;
    return found;
}
