#include "util.hpp"

#include <charconv>
#include <limits>

namespace conduit {

namespace {

constexpr char kHex[] = "0123456789abcdef";

bool NeedsEscape(unsigned char c) { return c < 0x20 || c == '"' || c == '\\'; }

void Put2(char* p, unsigned v) {
    p[0] = static_cast<char>('0' + v / 10);
    p[1] = static_cast<char>('0' + v % 10);
}

std::int64_t FloorDiv(std::int64_t a, std::int64_t b) {
    std::int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) --q;
    return q;
}

constexpr char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

constexpr int B64Val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

}  // namespace

void JsonOut::Str(std::string_view v) {
    s_.push_back('"');
    std::size_t start = 0;
    for (std::size_t i = 0; i < v.size(); ++i) {
        const auto c = static_cast<unsigned char>(v[i]);
        if (!NeedsEscape(c)) continue;
        s_.append(v.data() + start, i - start);
        start = i + 1;
        switch (c) {
            case '"': s_.append("\\\""); break;
            case '\\': s_.append("\\\\"); break;
            case '\n': s_.append("\\n"); break;
            case '\r': s_.append("\\r"); break;
            case '\t': s_.append("\\t"); break;
            case '\b': s_.append("\\b"); break;
            case '\f': s_.append("\\f"); break;
            default: {
                const char buf[6] = {'\\', 'u', '0', '0', kHex[c >> 4], kHex[c & 15]};
                s_.append(buf, 6);
            }
        }
    }
    s_.append(v.data() + start, v.size() - start);
    s_.push_back('"');
}

void JsonOut::Int(std::int64_t v) {
    char buf[24];
    auto [end, ec] = std::to_chars(buf, buf + sizeof(buf), v);
    s_.append(buf, end);
}

void JsonOut::Time(std::chrono::system_clock::time_point tp) {
    using namespace std::chrono;
    const std::int64_t ms = FloorDiv(duration_cast<microseconds>(tp.time_since_epoch()).count(), 1000);
    const std::int64_t secs = FloorDiv(ms, 1000);
    const std::int64_t days = FloorDiv(secs, 86400);
    const std::int64_t sod = secs - days * 86400;
    const year_month_day ymd{sys_days{std::chrono::days{days}}};

    char buf[26];
    const int y = static_cast<int>(ymd.year());
    buf[0] = '"';
    buf[1] = static_cast<char>('0' + (y / 1000) % 10);
    buf[2] = static_cast<char>('0' + (y / 100) % 10);
    buf[3] = static_cast<char>('0' + (y / 10) % 10);
    buf[4] = static_cast<char>('0' + y % 10);
    buf[5] = '-';
    Put2(buf + 6, static_cast<unsigned>(ymd.month()));
    buf[8] = '-';
    Put2(buf + 9, static_cast<unsigned>(ymd.day()));
    buf[11] = 'T';
    Put2(buf + 12, static_cast<unsigned>(sod / 3600));
    buf[14] = ':';
    Put2(buf + 15, static_cast<unsigned>((sod / 60) % 60));
    buf[17] = ':';
    Put2(buf + 18, static_cast<unsigned>(sod % 60));
    buf[20] = '.';
    const auto frac = static_cast<unsigned>(ms - secs * 1000);
    buf[21] = static_cast<char>('0' + frac / 100);
    buf[22] = static_cast<char>('0' + (frac / 10) % 10);
    buf[23] = static_cast<char>('0' + frac % 10);
    buf[24] = 'Z';
    buf[25] = '"';
    s_.append(buf, 26);
}

std::string Base64UrlEncode(std::string_view in) {
    std::string out;
    out.reserve((in.size() * 4 + 2) / 3);
    std::size_t i = 0;
    for (; i + 3 <= in.size(); i += 3) {
        const std::uint32_t v = (static_cast<unsigned char>(in[i]) << 16) |
                                (static_cast<unsigned char>(in[i + 1]) << 8) | static_cast<unsigned char>(in[i + 2]);
        out.push_back(kB64[(v >> 18) & 63]);
        out.push_back(kB64[(v >> 12) & 63]);
        out.push_back(kB64[(v >> 6) & 63]);
        out.push_back(kB64[v & 63]);
    }
    const std::size_t rest = in.size() - i;
    if (rest == 1) {
        const std::uint32_t v = static_cast<unsigned char>(in[i]) << 16;
        out.push_back(kB64[(v >> 18) & 63]);
        out.push_back(kB64[(v >> 12) & 63]);
    } else if (rest == 2) {
        const std::uint32_t v = (static_cast<unsigned char>(in[i]) << 16) | (static_cast<unsigned char>(in[i + 1]) << 8);
        out.push_back(kB64[(v >> 18) & 63]);
        out.push_back(kB64[(v >> 12) & 63]);
        out.push_back(kB64[(v >> 6) & 63]);
    }
    return out;
}

bool Base64UrlDecode(std::string_view in, std::string& out) {
    if (in.size() % 4 == 1) return false;
    out.clear();
    out.reserve(in.size() * 3 / 4);
    std::uint32_t acc = 0;
    int bits = 0;
    for (const char c : in) {
        const int v = B64Val(c);
        if (v < 0) return false;
        acc = (acc << 6) | static_cast<std::uint32_t>(v);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back(static_cast<char>((acc >> bits) & 0xFF));
        }
    }
    return true;
}

bool ParseUint(std::string_view s, std::int64_t& out) {
    if (s.empty()) return false;
    for (const char c : s) {
        if (c < '0' || c > '9') return false;
    }
    auto [end, ec] = std::from_chars(s.data(), s.data() + s.size(), out);
    return ec == std::errc{} && end == s.data() + s.size();
}

}  // namespace conduit
