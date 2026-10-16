// Small helpers: JSON output, timestamps, base64url, URL decoding, integer parsing.
#pragma once
#include <emmintrin.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>

// ---------- JSON output ----------

// Appends s as a JSON string literal (quotes included).
inline void json_str(std::string& o, std::string_view s) {
  static const char hex[] = "0123456789abcdef";
  o.push_back('"');
  const char* p = s.data();
  const char* end = p + s.size();
  const char* run = p;
  const __m128i quote = _mm_set1_epi8('"'), bslash = _mm_set1_epi8('\\'), ctl = _mm_set1_epi8(0x1f);
  for (; p < end; ++p) {
    // skip 16 bytes at a time while none of them needs escaping
    while (end - p >= 16) {
      __m128i v = _mm_loadu_si128(reinterpret_cast<const __m128i*>(p));
      __m128i bad = _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, quote), _mm_cmpeq_epi8(v, bslash)),
                                 _mm_cmpeq_epi8(_mm_min_epu8(v, ctl), v));  // v <= 0x1f (unsigned)
      int m = _mm_movemask_epi8(bad);
      if (m) {
        p += __builtin_ctz(unsigned(m));
        break;
      }
      p += 16;
    }
    if (p == end) break;
    unsigned char ch = static_cast<unsigned char>(*p);
    if (ch >= 0x20 && ch != '"' && ch != '\\') continue;
    o.append(run, p - run);
    switch (ch) {
      case '"': o.append("\\\""); break;
      case '\\': o.append("\\\\"); break;
      case '\n': o.append("\\n"); break;
      case '\r': o.append("\\r"); break;
      case '\t': o.append("\\t"); break;
      default: {
        char u[6] = {'\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 15]};
        o.append(u, 6);
      }
    }
    run = p + 1;
  }
  o.append(run, end - run);
  o.push_back('"');
}

inline void json_int(std::string& o, int64_t v) {
  char buf[24];
  char* e = buf + sizeof buf;
  char* p = e;
  bool neg = v < 0;
  uint64_t u = neg ? 0 - static_cast<uint64_t>(v) : static_cast<uint64_t>(v);
  do { *--p = char('0' + u % 10); u /= 10; } while (u);
  if (neg) *--p = '-';
  o.append(p, e - p);
}

// Postgres binary timestamptz (microseconds since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ" (quoted, ms truncated).
inline void json_ts(std::string& o, int64_t pg_us) {
  // shift to the Unix epoch, floor to milliseconds
  int64_t us = pg_us + 946684800LL * 1000000LL;
  int64_t ms = us >= 0 ? us / 1000 : -((-us + 999) / 1000);
  int64_t secs = ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000);
  int msr = int(ms - secs * 1000);
  int64_t days = secs >= 0 ? secs / 86400 : -((-secs + 86399) / 86400);
  int sod = int(secs - days * 86400);
  // civil_from_days (Howard Hinnant)
  int64_t z = days + 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = unsigned(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t y = int64_t(yoe) + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  unsigned d = doy - (153 * mp + 2) / 5 + 1;
  unsigned m = mp < 10 ? mp + 3 : mp - 9;
  if (m <= 2) ++y;
  char b[26];
  auto two = [](char* p, unsigned v) { p[0] = char('0' + v / 10); p[1] = char('0' + v % 10); };
  b[0] = '"';
  unsigned yy = unsigned(y);
  b[1] = char('0' + yy / 1000 % 10); b[2] = char('0' + yy / 100 % 10); b[3] = char('0' + yy / 10 % 10); b[4] = char('0' + yy % 10);
  b[5] = '-'; two(b + 6, m); b[8] = '-'; two(b + 9, d); b[11] = 'T';
  two(b + 12, unsigned(sod / 3600)); b[14] = ':'; two(b + 15, unsigned(sod / 60 % 60)); b[17] = ':'; two(b + 18, unsigned(sod % 60));
  b[20] = '.'; b[21] = char('0' + msr / 100); b[22] = char('0' + msr / 10 % 10); b[23] = char('0' + msr % 10);
  b[24] = 'Z'; b[25] = '"';
  o.append(b, 26);
}

// ---------- integers ----------

// ASCII digits only, no sign, fits in int64 (Go reference's parseUint).
inline bool parse_uint(std::string_view s, int64_t& out) {
  if (s.empty()) return false;
  uint64_t v = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return false;
    if (v > (uint64_t(INT64_MAX) - uint64_t(c - '0')) / 10) return false;
    v = v * 10 + uint64_t(c - '0');
  }
  out = int64_t(v);
  return true;
}

inline char* fmt_int(char* buf, int64_t v) {  // writes a NUL-terminated decimal, returns buf
  char tmp[24];
  char* p = tmp + sizeof tmp;
  *--p = 0;
  bool neg = v < 0;
  uint64_t u = neg ? 0 - uint64_t(v) : uint64_t(v);
  do { *--p = char('0' + u % 10); u /= 10; } while (u);
  if (neg) *--p = '-';
  std::memcpy(buf, p, size_t(tmp + sizeof tmp - p));
  return buf;
}

// ---------- base64url (no padding) ----------

inline void b64url_encode(std::string& o, const unsigned char* d, size_t n) {
  static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  size_t i = 0;
  for (; i + 3 <= n; i += 3) {
    uint32_t v = (uint32_t(d[i]) << 16) | (uint32_t(d[i + 1]) << 8) | d[i + 2];
    char c[4] = {tbl[v >> 18], tbl[(v >> 12) & 63], tbl[(v >> 6) & 63], tbl[v & 63]};
    o.append(c, 4);
  }
  if (n - i == 1) {
    uint32_t v = uint32_t(d[i]) << 16;
    o.push_back(tbl[v >> 18]); o.push_back(tbl[(v >> 12) & 63]);
  } else if (n - i == 2) {
    uint32_t v = (uint32_t(d[i]) << 16) | (uint32_t(d[i + 1]) << 8);
    o.push_back(tbl[v >> 18]); o.push_back(tbl[(v >> 12) & 63]); o.push_back(tbl[(v >> 6) & 63]);
  }
}

// Decodes RFC 4648 base64url without padding (Go's RawURLEncoding). Returns false on any invalid input.
inline bool b64url_decode(std::string_view s, unsigned char* out, size_t cap, size_t& n) {
  static const signed char* tbl = [] {
    static signed char t[256];
    std::memset(t, -1, sizeof t);
    const char* a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    for (int i = 0; i < 64; ++i) t[static_cast<unsigned char>(a[i])] = static_cast<signed char>(i);
    return t;
  }();
  if (s.size() % 4 == 1) return false;
  size_t need = s.size() / 4 * 3 + (s.size() % 4 ? s.size() % 4 - 1 : 0);
  if (need > cap) return false;
  n = 0;
  uint32_t acc = 0;
  int bits = 0;
  for (char c : s) {
    int v = tbl[static_cast<unsigned char>(c)];
    if (v < 0) return false;
    acc = (acc << 6) | uint32_t(v);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[n++] = static_cast<unsigned char>(acc >> bits);
    }
  }
  return true;
}

// ---------- URL decoding ----------

inline int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Percent-decodes s into out. plus_space: '+' means ' ' (query strings). Returns false on a bad escape.
inline bool url_decode(std::string_view s, std::string& out, bool plus_space) {
  out.clear();
  for (size_t i = 0; i < s.size(); ++i) {
    char c = s[i];
    if (c == '%') {
      if (i + 2 >= s.size()) return false;
      int h = hexval(s[i + 1]), l = hexval(s[i + 2]);
      if (h < 0 || l < 0) return false;
      out.push_back(char(h * 16 + l));
      i += 2;
    } else if (c == '+' && plus_space) {
      out.push_back(' ');
    } else {
      out.push_back(c);
    }
  }
  return true;
}

inline int64_t be64(const char* p) {
  uint64_t v;
  std::memcpy(&v, p, 8);
  return int64_t(__builtin_bswap64(v));
}
inline int32_t be32(const char* p) {
  uint32_t v;
  std::memcpy(&v, p, 4);
  return int32_t(__builtin_bswap32(v));
}
