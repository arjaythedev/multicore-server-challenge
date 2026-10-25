// Small encoders/decoders: base64url, percent-decoding, binary Postgres values, RFC 3339 timestamps.
#pragma once
#include <libpq-fe.h>

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

inline int b64val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

// Unpadded base64url; returns false on any invalid character or length.
inline bool b64url_decode(std::string_view s, std::string &out) {
    out.clear();
    if (s.size() % 4 == 1) return false;
    uint32_t acc = 0;
    int bits = 0;
    for (char c : s) {
        int v = b64val(c);
        if (v < 0) return false;
        acc = acc << 6 | uint32_t(v);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back(char(acc >> bits & 0xff));
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
    char b[40];
    int n = snprintf(b, sizeof b, "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ", (long long)y, (long long)m,
                     (long long)d, (long long)(sod / 3600), (long long)(sod % 3600 / 60), (long long)(sod % 60),
                     (long long)(rem / 1000));
    o.append(b, size_t(n));
}

// Accessors for binary-format result columns.
inline bool is_null(PGresult *r, int row, int col) { return PQgetisnull(r, row, col) != 0; }
inline std::string_view text(PGresult *r, int row, int col) {
    return {PQgetvalue(r, row, col), size_t(PQgetlength(r, row, col))};
}
inline int64_t i64(PGresult *r, int row, int col) { return be64(PQgetvalue(r, row, col)); }
inline bool boolean(PGresult *r, int row, int col) { return PQgetvalue(r, row, col)[0] != 0; }

}  // namespace codec
