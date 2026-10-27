// Small encoders/decoders: base64url, percent-decoding, binary Postgres values, RFC 3339 timestamps.
#pragma once
#include "pgres.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <string_view>

namespace codec {

inline std::string b64url_encode(const unsigned char *d, size_t n) {
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string o;
    o.reserve((n + 2) / 3 * 4);
    size_t i = 0;
    for (; i + 2 < n; i += 3) {
        uint32_t v = d[i] << 16 | d[i + 1] << 8 | d[i + 2];
        o.push_back(t[v >> 18]);
        o.push_back(t[v >> 12 & 63]);
        o.push_back(t[v >> 6 & 63]);
        o.push_back(t[v & 63]);
    }
    if (n - i == 1) {
        uint32_t v = d[i] << 16;
        o.push_back(t[v >> 18]);
        o.push_back(t[v >> 12 & 63]);
    } else if (n - i == 2) {
        uint32_t v = d[i] << 16 | d[i + 1] << 8;
        o.push_back(t[v >> 18]);
        o.push_back(t[v >> 12 & 63]);
        o.push_back(t[v >> 6 & 63]);
    }
    return o;
}

// 0..63 for base64url characters, -1 otherwise.
struct B64Table {
    int8_t v[256];
    constexpr B64Table() : v() {
        for (int i = 0; i < 256; i++) v[i] = -1;
        for (int i = 0; i < 26; i++) v['A' + i] = int8_t(i), v['a' + i] = int8_t(26 + i);
        for (int i = 0; i < 10; i++) v['0' + i] = int8_t(52 + i);
        v[int('-')] = 62;
        v[int('_')] = 63;
    }
};
alignas(64) inline constexpr B64Table kB64{};

inline int b64val(char c) { return kB64.v[static_cast<unsigned char>(c)]; }

// Unpadded base64url; returns false on any invalid character or length.
inline bool b64url_decode(std::string_view s, std::string &out) {
    out.clear();
    if (s.size() % 4 == 1) return false;
    out.resize(s.size() * 6 / 8);
    char *w = out.data();
    uint32_t acc = 0;
    int bits = 0;
    for (char c : s) {
        int v = b64val(c);
        if (v < 0) [[unlikely]] return false;
        acc = acc << 6 | uint32_t(v);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            *w++ = char(acc >> bits & 0xff);
        }
    }
    return true;
}

inline int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Percent-decoding; `plus` turns '+' into a space (query strings).
inline std::string pct_decode(std::string_view s, bool plus) {
    std::string o;
    o.reserve(s.size());
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '%' && i + 2 < s.size() &&hexval(s[i + 1]) >= 0 && hexval(s[i + 2]) >= 0) {
            o.push_back(char(hexval(s[i + 1]) << 4 | hexval(s[i + 2])));
            i += 2;
        } else if (plus && s[i] == '+') {
            o.push_back(' ');
        } else {
            o.push_back(s[i]);
        }
    }
    return o;
}

inline int64_t be64(const char *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return int64_t(__builtin_bswap64(v));
}
inline int32_t be32(const char *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return int32_t(__builtin_bswap32(v));
}

// Appends a binary timestamptz (microseconds since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ" (truncating).
inline void append_ts(std::string &o, int64_t us) {
    int64_t secs = us / 1000000, rem = us % 1000000;
    if (rem < 0) {
        rem += 1000000;
        secs--;
    }
    int64_t days = secs / 86400, sod = secs % 86400;
    if (sod < 0) {
        sod += 86400;
        days--;
    }
    days += 10957 + 719468;  // 1970-01-01 is 10957 days before 2000-01-01; shift to 0000-03-01 for the algorithm
    int64_t era = (days >= 0 ? days : days - 146096) / 146097;
    int64_t doe = days - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    int64_t d = doy - (153 * mp + 2) / 5 + 1;
    int64_t m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) y++;
    if (y >= 0 && y <= 9999) {  // fixed-width fast path, same bytes as the snprintf below
        char b[24];
        auto two = [&](int at, int64_t v) {
            b[at] = char('0' + v / 10);
            b[at + 1] = char('0' + v % 10);
        };
        two(0, y / 100), two(2, y % 100);
        b[4] = '-', two(5, m), b[7] = '-', two(8, d), b[10] = 'T';
        two(11, sod / 3600), b[13] = ':', two(14, sod % 3600 / 60), b[16] = ':', two(17, sod % 60), b[19] = '.';
        int64_t ms = rem / 1000;
        b[20] = char('0' + ms / 100), two(21, ms % 100), b[23] = 'Z';
        o.append(b, 24);
        return;
    }
    char b[40];
    int n = snprintf(b, sizeof b, "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ", (long long)y, (long long)m,
                     (long long)d, (long long)(sod / 3600), (long long)(sod % 3600 / 60), (long long)(sod % 60),
                     (long long)(rem / 1000));
    o.append(b, size_t(n));
}

// Accessors for binary-format result columns.
inline bool is_null(const PgResult *r, int row, int col) { return r->null(row, col); }
inline std::string_view text(const PgResult *r, int row, int col) {
    return {r->value(row, col), size_t(r->length(row, col))};
}
inline int64_t i64(const PgResult *r, int row, int col) { return be64(r->value(row, col)); }
inline bool boolean(const PgResult *r, int row, int col) { return r->value(row, col)[0] != 0; }

}  // namespace codec
