#include "json_out.h"

/* 0: copy as is; otherwise the character after the backslash, or 'u' for \u00XX. */
static const char esc[256] = {
    'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'b', 't', 'n', 'u', 'f', 'r', 'u', 'u',
    'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u', 'u',
    [(unsigned char)'"'] = '"',
    [(unsigned char)'\\'] = '\\',
};

void json_str(struct buf *b, const char *s, size_t n) {
    /* Worst case every byte becomes \u00XX. */
    char *d = buf_reserve(b, n * 6 + 2), *start = d;
    *d++ = '"';
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        char e = esc[c];
        if (likely(!e)) {
            *d++ = (char)c;
        } else if (e != 'u') {
            *d++ = '\\';
            *d++ = e;
        } else {
            static const char hex[] = "0123456789abcdef";
            memcpy(d, "\\u00", 4);
            d[4] = hex[c >> 4];
            d[5] = hex[c & 15];
            d += 6;
        }
    }
    *d++ = '"';
    b->len += (size_t)(d - start);
}

static inline void two(char *d, unsigned v) {
    d[0] = (char)('0' + v / 10);
    d[1] = (char)('0' + v % 10);
}

void fmt_ts(char out[TS_LEN], int64_t pg_us) {
    int64_t us = pg_us + PG_EPOCH_UNIX_US;
    int64_t day_us = INT64_C(86400000000);
    int64_t days = us / day_us, rem = us % day_us;
    if (rem < 0) rem += day_us, days--;

    /* Civil date from days since 1970-01-01 (proleptic Gregorian). */
    int64_t z = days + 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned mp = (5 * doy + 2) / 153;
    unsigned d = doy - (153 * mp + 2) / 5 + 1;
    unsigned m = mp < 10 ? mp + 3 : mp - 9;
    int64_t y = (int64_t)yoe + era * 400 + (m <= 2);

    unsigned secs = (unsigned)(rem / 1000000), ms = (unsigned)(rem % 1000000 / 1000);
    unsigned yy = (unsigned)y;
    two(out, yy / 100 % 100);
    two(out + 2, yy % 100);
    out[4] = '-';
    two(out + 5, m);
    out[7] = '-';
    two(out + 8, d);
    out[10] = 'T';
    two(out + 11, secs / 3600);
    out[13] = ':';
    two(out + 14, secs / 60 % 60);
    out[16] = ':';
    two(out + 17, secs % 60);
    out[19] = '.';
    out[20] = (char)('0' + ms / 100);
    two(out + 21, ms % 100);
    out[23] = 'Z';
}

void json_ts(struct buf *b, int64_t pg_us) {
    char *d = buf_reserve(b, TS_LEN + 2);
    d[0] = '"';
    fmt_ts(d + 1, pg_us);
    d[TS_LEN + 1] = '"';
    b->len += TS_LEN + 2;
}
