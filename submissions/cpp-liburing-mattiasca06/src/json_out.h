// Hand-written JSON output helpers.
#pragma once
#include <cstdint>
#include <cstring>
#include <string>
#if defined(__x86_64__)
#include <immintrin.h>
#endif

namespace json {

inline constexpr char kHex[] = "0123456789abcdef";

// Appends a string literal. std::string::append is an out-of-line libstdc++ call (strlen + memcpy through the PLT); with the
// length known at compile time this writes the bytes inline instead.
template <size_t N> inline void lit(std::string &o, const char (&s)[N]) {
#if defined(_GLIBCXX_RELEASE) && _GLIBCXX_RELEASE >= 15
    const size_t at = o.size();
    o.__resize_and_overwrite(at + N - 1, [&](char *p, size_t) {
        memcpy(p + at, s, N - 1);
        return at + N - 1;
    });
#else
    o.append(s, N - 1);
#endif
}

// First index >= i whose byte needs escaping (`"`, `\`, or < 0x20); n if none.
// x86-64: SSE2 (always present) 16 bytes at a time, AVX2 32 bytes at a time when the CPU has it (checked at run time,
// so the binary does not depend on the build machine's -march). Other targets: plain loop.
#if defined(__x86_64__)
__attribute__((target("avx2"))) inline size_t next_special_avx2(const char *s, size_t i, size_t n) {
    const __m256i quote = _mm256_set1_epi8('"'), bslash = _mm256_set1_epi8('\\'), ctl = _mm256_set1_epi8(0x1f);
    for (; i + 32 <= n; i += 32) {
        __m256i v = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(s + i));
        // byte < 0x20  <=>  min_epu8(v, 0x1f) == v
        __m256i m = _mm256_or_si256(_mm256_or_si256(_mm256_cmpeq_epi8(v, quote), _mm256_cmpeq_epi8(v, bslash)),
                                    _mm256_cmpeq_epi8(_mm256_min_epu8(v, ctl), v));
        uint32_t bits = static_cast<uint32_t>(_mm256_movemask_epi8(m));
        if (bits) return i + __builtin_ctz(bits);
    }
    return i;
}

inline bool have_avx2() {
    static const bool v = __builtin_cpu_supports("avx2");
    return v;
}
#endif

inline size_t next_special(const char *s, size_t i, size_t n) {
#if defined(__x86_64__)
    if (n - i >= 32 && have_avx2()) i = next_special_avx2(s, i, n);
    const __m128i quote = _mm_set1_epi8('"'), bslash = _mm_set1_epi8('\\'), ctl = _mm_set1_epi8(0x1f);
    for (; i + 16 <= n; i += 16) {
        __m128i v = _mm_loadu_si128(reinterpret_cast<const __m128i *>(s + i));
        __m128i m = _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, quote), _mm_cmpeq_epi8(v, bslash)),
                                 _mm_cmpeq_epi8(_mm_min_epu8(v, ctl), v));
        uint32_t bits = static_cast<uint32_t>(_mm_movemask_epi8(m));
        if (bits) return i + __builtin_ctz(bits);
    }
#endif
    for (; i < n; i++) {
        unsigned char ch = static_cast<unsigned char>(s[i]);
        if (ch < 0x20 || ch == '"' || ch == '\\') return i;
    }
    return n;
}

// Appends `s` as a quoted JSON string. Only `"`, `\` and bytes < 0x20 are escaped; other bytes (UTF-8) pass through.
inline void str(std::string &o, const char *s, size_t n) {
    size_t i = next_special(s, 0, n);
#if defined(_GLIBCXX_RELEASE) && _GLIBCXX_RELEASE >= 15
    if (i == n) [[likely]] {  // nothing to escape (the common case): quotes and bytes in one write
        const size_t at = o.size();
        o.__resize_and_overwrite(at + n + 2, [&](char *p, size_t) {
            p[at] = '"';
            memcpy(p + at + 1, s, n);
            p[at + n + 1] = '"';
            return at + n + 2;
        });
        return;
    }
#endif
    o.push_back('"');
    size_t run = 0;
    for (; i < n; i = next_special(s, i + 1, n)) {
        unsigned char ch = static_cast<unsigned char>(s[i]);
        o.append(s + run, i - run);
        run = i + 1;
        switch (ch) {
        case '"': o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break;
        case '\r': o += "\\r"; break;
        case '\t': o += "\\t"; break;
        case '\b': o += "\\b"; break;
        case '\f': o += "\\f"; break;
        default:
            o += "\\u00";
            o.push_back(kHex[ch >> 4]);
            o.push_back(kHex[ch & 15]);
        }
    }
    o.append(s + run, n - run);
    o.push_back('"');
}

}  // namespace json
