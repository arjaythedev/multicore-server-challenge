#ifndef JSON_SIMD_H
#define JSON_SIMD_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#endif

#include "conduit.h"


// Fast integer to string conversions
static inline int u64_to_str(uint64_t v, char *out) {
    char temp[24];
    int p = 0;
    if (v == 0) {
        out[0] = '0';
        out[1] = '\0';
        return 1;
    }
    while (v > 0) {
        temp[p++] = (char)('0' + (v % 10));
        v /= 10;
    }
    for (int i = 0; i < p; i++) {
        out[i] = temp[p - 1 - i];
    }
    out[p] = '\0';
    return p;
}

static inline int i64_to_str(int64_t v, char *out) {
    if (v < 0) {
        out[0] = '-';
        return 1 + u64_to_str((uint64_t)(-v), out + 1);
    }
    return u64_to_str((uint64_t)v, out);
}

// Convert text timestamp from PostgreSQL ("YYYY-MM-DD HH:MM:SS.ssssss+00")
// to RFC 3339 UTC with exactly 3 fractional digits ("YYYY-MM-DDTHH:MM:SS.sssZ")
static inline void pg_text_to_rfc3339(const char *in, int in_len, char *out) {
    if (!in || in_len < 19) {
        strcpy(out, "1970-01-01T00:00:00.000Z");
        return;
    }
    memcpy(out, in, 10); // "YYYY-MM-DD"
    out[10] = 'T';
    memcpy(out + 11, in + 11, 8); // "HH:MM:SS"
    out[19] = '.';
    if (in_len > 19 && in[19] == '.') {
        const char *dot = in + 20;
        int p = 0;
        while (p < 3 && (20 + p) < in_len && dot[p] >= '0' && dot[p] <= '9') {
            out[20 + p] = dot[p];
            p++;
        }
        while (p < 3) {
            out[20 + p] = '0';
            p++;
        }
    } else {
        out[20] = '0';
        out[21] = '0';
        out[22] = '0';
    }
    out[23] = 'Z';
    out[24] = '\0';
}

// Pre-compute slugify in C
// trim(both '-' from lower(regexp_replace(title, '[^A-Za-z0-9]+', '-', 'g')))
static inline size_t slugify_title(const char *src, size_t len, char *dst) {
    size_t out = 0;
    int in_dash = 1;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)src[i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            dst[out++] = (char)c;
            in_dash = 0;
        } else if (c >= 'A' && c <= 'Z') {
            dst[out++] = (char)(c | 0x20);
            in_dash = 0;
        } else if (!in_dash) {
            dst[out++] = '-';
            in_dash = 1;
        }
    }
    if (out > 0 && dst[out - 1] == '-') {
        out--;
    }
    dst[out] = '\0';
    return out;
}

// Append JSON-escaped string directly into http_res_t buffer
static inline void res_append_escaped(http_res_t *res, const char *src, int len) {
    if (!src || len <= 0) return;
    int i = 0;
#if defined(__AVX2__)
    __m256i quote = _mm256_set1_epi8('"');
    __m256i backslash = _mm256_set1_epi8('\\');
    __m256i ctrl_thresh = _mm256_set1_epi8((char)(0x20 ^ 0x80));
    __m256i xor80 = _mm256_set1_epi8((char)0x80);

    while (i + 32 <= len && res->len + 32 + 6 < res->cap) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(src + i));
        __m256i m1 = _mm256_cmpeq_epi8(v, quote);
        __m256i m2 = _mm256_cmpeq_epi8(v, backslash);
        __m256i v_signed = _mm256_xor_si256(v, xor80);
        __m256i m3 = _mm256_cmpgt_epi8(ctrl_thresh, v_signed);
        __m256i mask = _mm256_or_si256(_mm256_or_si256(m1, m2), m3);

        if (_mm256_testz_si256(mask, mask)) {
            _mm256_storeu_si256((__m256i *)(res->buf + res->len), v);
            res->len += 32;
            i += 32;
        } else {
            uint32_t bitmask = (uint32_t)_mm256_movemask_epi8(mask);
            int hit = __builtin_ctz(bitmask);
            if (hit > 0) {
                memcpy(res->buf + res->len, src + i, hit);
                res->len += hit;
                i += hit;
            }
            unsigned char c = (unsigned char)src[i++];
            switch (c) {
                case '"':  res->buf[res->len++] = '\\'; res->buf[res->len++] = '"'; break;
                case '\\': res->buf[res->len++] = '\\'; res->buf[res->len++] = '\\'; break;
                case '\b': res->buf[res->len++] = '\\'; res->buf[res->len++] = 'b'; break;
                case '\f': res->buf[res->len++] = '\\'; res->buf[res->len++] = 'f'; break;
                case '\n': res->buf[res->len++] = '\\'; res->buf[res->len++] = 'n'; break;
                case '\r': res->buf[res->len++] = '\\'; res->buf[res->len++] = 'r'; break;
                case '\t': res->buf[res->len++] = '\\'; res->buf[res->len++] = 't'; break;
                default:
                    if (c < 0x20) {
                        static const char hex[] = "0123456789abcdef";
                        res->buf[res->len++] = '\\'; res->buf[res->len++] = 'u';
                        res->buf[res->len++] = '0';  res->buf[res->len++] = '0';
                        res->buf[res->len++] = hex[(c >> 4) & 0xf];
                        res->buf[res->len++] = hex[c & 0xf];
                    } else {
                        res->buf[res->len++] = (char)c;
                    }
                    break;
            }
        }
    }
#endif
    while (i < len && res->len + 6 < res->cap) {
        unsigned char c = (unsigned char)src[i++];
        switch (c) {
            case '"':  res->buf[res->len++] = '\\'; res->buf[res->len++] = '"'; break;
            case '\\': res->buf[res->len++] = '\\'; res->buf[res->len++] = '\\'; break;
            case '\b': res->buf[res->len++] = '\\'; res->buf[res->len++] = 'b'; break;
            case '\f': res->buf[res->len++] = '\\'; res->buf[res->len++] = 'f'; break;
            case '\n': res->buf[res->len++] = '\\'; res->buf[res->len++] = 'n'; break;
            case '\r': res->buf[res->len++] = '\\'; res->buf[res->len++] = 'r'; break;
            case '\t': res->buf[res->len++] = '\\'; res->buf[res->len++] = 't'; break;
            default:
                if (c < 0x20) {
                    static const char hex[] = "0123456789abcdef";
                    res->buf[res->len++] = '\\'; res->buf[res->len++] = 'u';
                    res->buf[res->len++] = '0';  res->buf[res->len++] = '0';
                    res->buf[res->len++] = hex[(c >> 4) & 0xf];
                    res->buf[res->len++] = hex[c & 0xf];
                } else {
                    res->buf[res->len++] = (char)c;
                }
                break;
        }
    }
    res->buf[res->len] = '\0';
}


// Deduplicate and sort tags in C
static inline int sort_dedup_tags(char **tags, int count) {
    if (count <= 1) return count;
    for (int i = 1; i < count; i++) {
        char *key = tags[i];
        int j = i - 1;
        while (j >= 0 && strcmp(tags[j], key) > 0) {
            tags[j + 1] = tags[j];
            j--;
        }
        tags[j + 1] = key;
    }
    int uniq = 1;
    for (int i = 1; i < count; i++) {
        if (strcmp(tags[i], tags[uniq - 1]) != 0) {
            tags[uniq++] = tags[i];
        }
    }
    return uniq;
}

#endif // JSON_SIMD_H
