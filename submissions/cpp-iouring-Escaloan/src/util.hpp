// Small shared helpers: branch hints, logging, byte-order, clocks, integer parsing.
#pragma once
#include <cerrno>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string_view>

#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

namespace util {

// Logging goes to stderr (the journal on the box). Only startup, errors and reconnects are logged in release.
[[gnu::format(printf, 1, 2)]] inline void log(const char* fmt, ...) {
  char buf[1024];
  std::timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  std::tm tm;
  gmtime_r(&ts.tv_sec, &tm);
  int n = std::snprintf(buf, sizeof buf, "%02d:%02d:%02d.%03ld ", tm.tm_hour, tm.tm_min, tm.tm_sec,
                        ts.tv_nsec / 1000000);
  va_list ap;
  va_start(ap, fmt);
  int m = std::vsnprintf(buf + n, sizeof buf - n - 1, fmt, ap);
  va_end(ap);
  if (m < 0) m = 0;
  std::size_t len = std::size_t(n) + std::size_t(m);
  if (len > sizeof buf - 2) len = sizeof buf - 2;
  buf[len++] = '\n';
  fwrite(buf, 1, len, stderr);
}

[[noreturn, gnu::format(printf, 1, 2)]] inline void die(const char* fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  log("fatal: %s", buf);
  std::_Exit(1);
}

// ---- big-endian load/store (Postgres wire format) ----
inline std::uint16_t be16(const char* p) {
  std::uint16_t v;
  std::memcpy(&v, p, 2);
  return __builtin_bswap16(v);
}
inline std::uint32_t be32(const char* p) {
  std::uint32_t v;
  std::memcpy(&v, p, 4);
  return __builtin_bswap32(v);
}
inline std::uint64_t be64(const char* p) {
  std::uint64_t v;
  std::memcpy(&v, p, 8);
  return __builtin_bswap64(v);
}
inline void put16(char* p, std::uint16_t v) {
  v = __builtin_bswap16(v);
  std::memcpy(p, &v, 2);
}
inline void put32(char* p, std::uint32_t v) {
  v = __builtin_bswap32(v);
  std::memcpy(p, &v, 4);
}
inline void put64(char* p, std::uint64_t v) {
  v = __builtin_bswap64(v);
  std::memcpy(p, &v, 8);
}

// ---- clocks ----
inline std::int64_t now_realtime_s() {
  std::timespec ts;
  clock_gettime(CLOCK_REALTIME_COARSE, &ts);
  return ts.tv_sec;
}
inline std::int64_t now_mono_ms() {
  std::timespec ts;
  clock_gettime(CLOCK_MONOTONIC_COARSE, &ts);
  return std::int64_t(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}
inline std::int64_t now_mono_us() {
  std::timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return std::int64_t(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

// Parses ASCII digits only (no sign, no spaces, no empty) into a non-negative int64. False on overflow.
// Matches the reference server: leading zeros are fine, "+5" and " 5" are not.
inline bool parse_uint(std::string_view s, std::int64_t& out) {
  if (s.empty()) return false;
  std::uint64_t v = 0;
  for (char c : s) {
    unsigned d = unsigned(c) - '0';
    if (d > 9) return false;
    if (v > (std::uint64_t(INT64_MAX) - d) / 10) return false;
    v = v * 10 + d;
  }
  out = std::int64_t(v);
  return true;
}

// Case-insensitive ASCII comparison of s against a lowercase literal.
inline bool ieq(std::string_view s, std::string_view lower) {
  if (s.size() != lower.size()) return false;
  for (std::size_t i = 0; i < s.size(); ++i) {
    char c = s[i];
    if (c >= 'A' && c <= 'Z') c = char(c + 32);
    if (c != lower[i]) return false;
  }
  return true;
}

}  // namespace util
