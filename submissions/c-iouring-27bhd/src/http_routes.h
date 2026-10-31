#ifndef HTTP_ROUTES_H
#define HTTP_ROUTES_H

#include "conduit.h"
#include "db.h"
#include "auth_crypto.h"
#include "json_simd.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Parse query string for an ASCII unsigned integer with overflow check
static inline bool parse_query_uint(const char *val, int64_t *out) {
    if (!val || *val == '\0') return false;
    int64_t n = 0;
    for (int i = 0; val[i]; i++) {
        if (val[i] < '0' || val[i] > '9') return false;
        int d = val[i] - '0';
        if (n > (9223372036854775807LL - d) / 10) return false; // overflow
        n = n * 10 + d;
    }
    *out = n;
    return true;
}

// Find query param (first occurrence wins).
static inline bool get_query_param(const char *query, const char *key, char *out, int max_len) {
    if (!query || !*query) return false;
    int klen = (int)strlen(key);
    const char *p = query;
    while (*p) {
        if ((p == query || *(p - 1) == '&') && strncmp(p, key, klen) == 0 && p[klen] == '=') {
            const char *v = p + klen + 1;
            int w = 0;
            while (*v && *v != '&') {
                if (w < max_len - 1) {
                    if (*v == '%' && isxdigit((unsigned char)*(v+1)) && isxdigit((unsigned char)*(v+2))) {
                        char hex[3] = { *(v+1), *(v+2), 0 };
                        out[w++] = (char)strtol(hex, NULL, 16);
                        v += 3;
                    } else if (*v == '+') {
                        out[w++] = ' ';
                        v++;
                    } else {
                        out[w++] = *v++;
                    }
                } else {
                    v++;
                }
            }
            out[w] = '\0';
            return true;
        }
        p++;
    }
    return false;
}

static inline const char *find_json_wrapper(const char *json, int len, const char *wrapper) {
    if (!json || len < 4) return NULL;
    char target[64];
    snprintf(target, sizeof(target), "\"%s\"", wrapper);
    const char *k = strstr(json, target);
    if (!k || (k - json) >= len) return NULL;
    k += strlen(target);
    while (k < json + len && (*k == ' ' || *k == '\t' || *k == '\r' || *k == '\n' || *k == ':')) k++;
    if (k >= json + len || *k != '{') return NULL;
    return k;
}

static inline int get_json_string(const char *obj, const char *key, char *out, int max_out, bool *is_null) {
    *is_null = false;
    char target[64];
    snprintf(target, sizeof(target), "\"%s\"", key);
    const char *p = strstr(obj, target);
    if (!p) return 0;
    p += strlen(target);
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n' || *p == ':') p++;
    if (strncmp(p, "null", 4) == 0) {
        *is_null = true;
        return 2;
    }
    if (*p != '"') return -1;
    p++;
    int w = 0;
    while (*p && *p != '"') {
        if (*p == '\\' && *(p + 1)) {
            p++;
            if (*p == 'n') { if (w < max_out - 1) out[w++] = '\n'; p++; }
            else if (*p == 'r') { if (w < max_out - 1) out[w++] = '\r'; p++; }
            else if (*p == 't') { if (w < max_out - 1) out[w++] = '\t'; p++; }
            else if (*p == '"') { if (w < max_out - 1) out[w++] = '"'; p++; }
            else if (*p == '\\') { if (w < max_out - 1) out[w++] = '\\'; p++; }
            else if (*p == '/') { if (w < max_out - 1) out[w++] = '/'; p++; }
            else if (*p == 'u' && isxdigit((unsigned char)p[1]) && isxdigit((unsigned char)p[2]) &&
                     isxdigit((unsigned char)p[3]) && isxdigit((unsigned char)p[4])) {
                char hex[5] = { p[1], p[2], p[3], p[4], 0 };
                uint32_t cp = (uint32_t)strtoul(hex, NULL, 16);
                p += 5;
                if (cp < 0x80) {
                    if (w < max_out - 1) out[w++] = (char)cp;
                } else if (cp < 0x800) {
                    if (w < max_out - 2) {
                        out[w++] = (char)(0xC0 | (cp >> 6));
                        out[w++] = (char)(0x80 | (cp & 0x3F));
                    }
                } else {
                    if (w < max_out - 3) {
                        out[w++] = (char)(0xE0 | (cp >> 12));
                        out[w++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        out[w++] = (char)(0x80 | (cp & 0x3F));
                    }
                }
            } else {
                if (w < max_out - 1) out[w++] = *p++;
            }
        } else {
            if (w < max_out - 1) out[w++] = *p++;
        }
    }
    out[w] = '\0';
    return 1;
}

static inline int get_json_tag_list(const char *obj, char **tags_out, char *tag_storage, int max_storage, int max_tags) {
    const char *p = strstr(obj, "\"tagList\"");
    if (!p) return 0;
    p += 9;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n' || *p == ':') p++;
    if (strncmp(p, "null", 4) == 0) return 0;
    if (*p != '[') return -1;
    p++;

    int count = 0;
    int st_pos = 0;
    while (*p && *p != ']') {
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n' || *p == ',') p++;
        if (*p == ']') break;
        if (*p != '"') return -1;
        p++;
        const char *start = p;
        while (*p && *p != '"') {
            if (*p == '\\' && *(p + 1)) p += 2;
            else p++;
        }
        int len = (int)(p - start);
        if (len == 0) return -1;
        if (count >= max_tags || st_pos + len + 1 >= max_storage) return -1;

        tags_out[count] = tag_storage + st_pos;
        memcpy(tags_out[count], start, len);
        tags_out[count][len] = '\0';
        st_pos += len + 1;
        count++;
        if (*p == '"') p++;
    }
    return count;
}

void handle_request(db_conn_t *db, http_req_t *req, http_res_t *res);

#endif // HTTP_ROUTES_H
