#include "api/api.h"

#include <string.h>

#include "util.h"

/* query strings are small (list endpoints only), decoded into caller bufs;
 * ABSENT and broken stay distinct */

static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* first key with a non-empty value slot; keys compared raw */
static bool find_key(const char *query, const char *key, const char **begin,
                     const char **end) {
    size_t key_len = strlen(key);
    for (const char *p = query; *p;) {
        const char *amp = strchr(p, '&');
        if (!amp) amp = p + strlen(p);
        const char *eq = memchr(p, '=', (size_t)(amp - p));
        if (eq && (size_t)(eq - p) == key_len && memcmp(p, key, key_len) == 0) {
            *begin = eq + 1;
            *end = amp;
            return true;
        }
        p = *amp == '&' ? amp + 1 : amp;
    }
    return false;
}

static query_result decode(const char *begin, const char *end, char *out,
                           size_t cap) {
    size_t n = 0;
    for (const char *p = begin; p < end; p++) {
        unsigned char c;
        if (*p == '+') {
            c = ' ';
        } else if (*p == '%') {
            if (end - p < 3) return QUERY_INVALID;
            int hi = hex_value(p[1]);
            int lo = hex_value(p[2]);
            if (hi < 0 || lo < 0) return QUERY_INVALID;
            c = (unsigned char)(hi * 16 + lo);
            p += 2;
        } else {
            c = (unsigned char)*p;
        }
        // decoded NUL would truncate downstream
        if (c == '\0') return QUERY_INVALID;
        if (n + 1 >= cap) return QUERY_INVALID;
        out[n++] = (char)c;
    }
    out[n] = '\0';
    return QUERY_OK;
}

query_result query_string(const char *query, const char *key, char *out,
                          size_t cap) {
    const char *begin;
    const char *end;
    if (!find_key(query, key, &begin, &end)) return QUERY_ABSENT;
    return decode(begin, end, out, cap);
}

query_result query_integer(const char *query, const char *key, long long *out) {
    const char *begin;
    const char *end;
    if (!find_key(query, key, &begin, &end)) return QUERY_ABSENT;

    size_t len = (size_t)(end - begin);
    if (len == 0) return QUERY_INVALID;
    /* plain digits, max 18: keeps strtoll off ERANGE */
    if (len > 18) return QUERY_INVALID;
    for (const char *p = begin; p < end; p++)
        if (*p < '0' || *p > '9') return QUERY_INVALID;

    char tmp[19];
    memcpy(tmp, begin, len);
    tmp[len] = '\0';
    *out = strtoll(tmp, NULL, 10);
    return QUERY_OK;
}
