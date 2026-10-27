// Streaming JSON writer into a slab buffer. The first cfg::kHeaderReserve bytes of the buffer are left free so
// the HTTP header block can be written in front of the body and sent with it in one call.
//
// Space policy: callers reserve room for what they are about to write (raw lengths + syntax). String escaping
// takes a fast path while no byte needs escaping and re-checks space when it emits an escape sequence, so
// ordinary text never pays for the worst-case x6 expansion.
#pragma once
#include <emmintrin.h>

#include <charconv>
#include <cstdint>
#include <cstring>
#include <string_view>

#include "config.hpp"
#include "pool.hpp"
#include "util.hpp"

struct JsonOut {
  SlabPool* pool = nullptr;
  Buf buf;
  std::size_t len = 0;       // write position (absolute offset in buf)
  bool failed = false;       // allocation failed; the response must become a 500
  std::uint32_t grows = 0;   // times the buffer moved to a larger class (stats)

  // Starts a response body in a fresh buffer of at least `initial` bytes.
  bool begin(SlabPool& p, std::size_t initial) {
    if (buf.p) release();
    pool = &p;
    failed = false;
    if (!buf_alloc(p, buf, initial + cfg::kHeaderReserve)) {
      failed = true;
      return false;
    }
    len = cfg::kHeaderReserve;
    return true;
  }
  void release() {
    if (pool) buf_free(*pool, buf);
    len = 0;
  }
  char* body() const { return buf.p + cfg::kHeaderReserve; }
  std::size_t body_len() const { return len - cfg::kHeaderReserve; }
  // Rewinds to an earlier position (e.g. to drop a partially written row).
  void truncate(std::size_t pos) { len = pos; }

  // Ensures n more bytes fit; moves to a larger slab class if needed.
  bool reserve(std::size_t n) {
    if (LIKELY(len + n <= buf.cap)) return true;
    return grow(len + n);
  }

  void raw(const char* s, std::size_t n) {
    if (UNLIKELY(!reserve(n))) return;
    std::memcpy(buf.p + len, s, n);
    len += n;
  }
  void raw(std::string_view s) { raw(s.data(), s.size()); }
  template <std::size_t N>
  void lit(const char (&s)[N]) {
    raw(s, N - 1);
  }
  void ch(char c) {
    if (UNLIKELY(!reserve(1))) return;
    buf.p[len++] = c;
  }
  void null() { lit("null"); }
  void boolean(bool b) {
    if (b) lit("true");
    else lit("false");
  }
  void i64(std::int64_t v) {
    if (UNLIKELY(!reserve(24))) return;
    auto r = std::to_chars(buf.p + len, buf.p + len + 24, v);
    len = std::size_t(r.ptr - buf.p);
  }

  // Writes a quoted, escaped JSON string. Input is valid UTF-8 (Postgres text); bytes >= 0x80 pass through.
  void str(const char* s, std::size_t n) {
    if (UNLIKELY(!reserve(n + 2))) return;
    buf.p[len++] = '"';
    std::size_t i = 0;
    while (i < n) {
      std::size_t run = next_escape(s + i, n - i);
      if (run) {
        if (UNLIKELY(!reserve(run + 1))) return;
        std::memcpy(buf.p + len, s + i, run);
        len += run;
        i += run;
        if (i == n) break;
      }
      escape_one(static_cast<unsigned char>(s[i]));
      ++i;
    }
    ch('"');
  }
  void str(std::string_view s) { str(s.data(), s.size()); }

  // Postgres binary timestamptz (microseconds since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ" (quoted),
  // truncated toward negative infinity to milliseconds.
  void pg_timestamp(std::int64_t us) {
    if (UNLIKELY(!reserve(26))) return;
    std::int64_t ms = us >= 0 ? us / 1000 : -((-us + 999) / 1000);
    constexpr std::int64_t kMsPerDay = 86400000;
    std::int64_t days = ms >= 0 ? ms / kMsPerDay : -((-ms + kMsPerDay - 1) / kMsPerDay);
    std::int64_t msday = ms - days * kMsPerDay;
    days += 10957;  // 1970-01-01 -> 2000-01-01
    // Howard Hinnant's civil_from_days.
    std::int64_t z = days + 719468;
    std::int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    std::int64_t doe = z - era * 146097;
    std::int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    std::int64_t y = yoe + era * 400;
    std::int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    std::int64_t mp = (5 * doy + 2) / 153;
    std::int64_t d = doy - (153 * mp + 2) / 5 + 1;
    std::int64_t m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) ++y;
    int hh = int(msday / 3600000), mi = int(msday / 60000 % 60), ss = int(msday / 1000 % 60), mss = int(msday % 1000);
    char* o = buf.p + len;
    o[0] = '"';
    if (y < 0 || y > 9999) y = y < 0 ? 0 : 9999;  // outside RFC 3339's range; clamp rather than overflow
    o[1] = char('0' + y / 1000);
    o[2] = char('0' + y / 100 % 10);
    o[3] = char('0' + y / 10 % 10);
    o[4] = char('0' + y % 10);
    o[5] = '-';
    o[6] = char('0' + m / 10);
    o[7] = char('0' + m % 10);
    o[8] = '-';
    o[9] = char('0' + d / 10);
    o[10] = char('0' + d % 10);
    o[11] = 'T';
    o[12] = char('0' + hh / 10);
    o[13] = char('0' + hh % 10);
    o[14] = ':';
    o[15] = char('0' + mi / 10);
    o[16] = char('0' + mi % 10);
    o[17] = ':';
    o[18] = char('0' + ss / 10);
    o[19] = char('0' + ss % 10);
    o[20] = '.';
    o[21] = char('0' + mss / 100);
    o[22] = char('0' + mss / 10 % 10);
    o[23] = char('0' + mss % 10);
    o[24] = 'Z';
    o[25] = '"';
    len += 26;
  }

 private:
  // Length of the prefix of [s, s+n) that needs no escaping.
  static std::size_t next_escape(const char* s, std::size_t n) {
    std::size_t i = 0;
    const __m128i quote = _mm_set1_epi8('"');
    const __m128i bslash = _mm_set1_epi8('\\');
    const __m128i ctl = _mm_set1_epi8(0x1F);
    for (; i + 16 <= n; i += 16) {
      __m128i v = _mm_loadu_si128(reinterpret_cast<const __m128i*>(s + i));
      __m128i m = _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, quote), _mm_cmpeq_epi8(v, bslash)),
                               _mm_cmpeq_epi8(_mm_max_epu8(v, ctl), ctl));  // v <= 0x1F (unsigned)
      int bits = _mm_movemask_epi8(m);
      if (bits) return i + std::size_t(__builtin_ctz(unsigned(bits)));
    }
    for (; i < n; ++i) {
      unsigned char c = static_cast<unsigned char>(s[i]);
      if (c < 0x20 || c == '"' || c == '\\') return i;
    }
    return n;
  }

  void escape_one(unsigned char c) {
    if (UNLIKELY(!reserve(6))) return;
    char* o = buf.p + len;
    o[0] = '\\';
    switch (c) {
      case '"': o[1] = '"'; len += 2; return;
      case '\\': o[1] = '\\'; len += 2; return;
      case '\n': o[1] = 'n'; len += 2; return;
      case '\r': o[1] = 'r'; len += 2; return;
      case '\t': o[1] = 't'; len += 2; return;
      case '\b': o[1] = 'b'; len += 2; return;
      case '\f': o[1] = 'f'; len += 2; return;
      default: {
        static constexpr char kHex[] = "0123456789abcdef";
        o[1] = 'u';
        o[2] = '0';
        o[3] = '0';
        o[4] = kHex[c >> 4];
        o[5] = kHex[c & 15];
        len += 6;
      }
    }
  }

  bool grow(std::size_t need) {
    if (failed) return false;
    Buf nb;
    // At least double, so repeated growth of heap-backed buffers stays linear overall.
    std::size_t want = need > std::size_t(buf.cap) * 2 ? need : std::size_t(buf.cap) * 2;
    if (!buf_alloc(*pool, nb, want)) {
      failed = true;
      return false;
    }
    std::memcpy(nb.p, buf.p, len);
    buf_free(*pool, buf);
    buf = nb;
    ++grows;
    return true;
  }
};
