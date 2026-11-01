#include "base64.h"

static const char url_alphabet[64] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
static const char std_alphabet[64] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Reverse tables: 0..63, or 0xff for a byte outside the alphabet. */
static uint8_t url_rev[256], std_rev[256];

__attribute__((constructor)) static void b64_tables(void) {
    memset(url_rev, 0xff, sizeof url_rev);
    memset(std_rev, 0xff, sizeof std_rev);
    for (int i = 0; i < 64; i++) {
        url_rev[(uint8_t)url_alphabet[i]] = (uint8_t)i;
        std_rev[(uint8_t)std_alphabet[i]] = (uint8_t)i;
    }
}

static size_t encode(char *dst, const uint8_t *s, size_t n, const char *abc, bool pad) {
    char *d = dst;
    for (; n >= 3; n -= 3, s += 3) {
        uint32_t v = (uint32_t)s[0] << 16 | (uint32_t)s[1] << 8 | s[2];
        *d++ = abc[v >> 18], *d++ = abc[v >> 12 & 63], *d++ = abc[v >> 6 & 63], *d++ = abc[v & 63];
    }
    if (n) {
        uint32_t v = (uint32_t)s[0] << 16 | (n == 2 ? (uint32_t)s[1] << 8 : 0);
        *d++ = abc[v >> 18], *d++ = abc[v >> 12 & 63];
        if (n == 2) *d++ = abc[v >> 6 & 63];
        else if (pad) *d++ = '=';
        if (pad) *d++ = '=';
    }
    return (size_t)(d - dst);
}

size_t b64url_encode(char *dst, const void *src, size_t n) { return encode(dst, src, n, url_alphabet, false); }
size_t b64_encode(char *dst, const void *src, size_t n) { return encode(dst, src, n, std_alphabet, true); }

/* Decodes unpadded input of any valid length (n % 4 != 1). */
static ptrdiff_t decode(uint8_t *dst, const char *src, size_t n, const uint8_t *rev) {
    uint8_t *d = dst;
    const uint8_t *s = (const uint8_t *)src;
    if (n % 4 == 1) return -1;
    for (; n >= 4; n -= 4, s += 4) {
        uint8_t a = rev[s[0]], b = rev[s[1]], c = rev[s[2]], e = rev[s[3]];
        if ((a | b | c | e) & 0x80) return -1;
        uint32_t v = (uint32_t)a << 18 | (uint32_t)b << 12 | (uint32_t)c << 6 | e;
        *d++ = (uint8_t)(v >> 16), *d++ = (uint8_t)(v >> 8), *d++ = (uint8_t)v;
    }
    if (n) {
        uint8_t a = rev[s[0]], b = rev[s[1]], c = n == 3 ? rev[s[2]] : 0;
        if ((a | b | c) & 0x80) return -1;
        uint32_t v = (uint32_t)a << 18 | (uint32_t)b << 12 | (uint32_t)c << 6;
        *d++ = (uint8_t)(v >> 16);
        if (n == 3) *d++ = (uint8_t)(v >> 8);
    }
    return d - dst;
}

ptrdiff_t b64url_decode(void *dst, const char *src, size_t n) { return decode(dst, src, n, url_rev); }

ptrdiff_t b64_decode(void *dst, const char *src, size_t n) {
    if (n % 4) return -1;
    if (n && src[n - 1] == '=') n--;
    if (n && src[n - 1] == '=') n--;
    return decode(dst, src, n, std_rev);
}
