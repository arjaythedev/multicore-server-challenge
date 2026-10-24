// Hand-written JSON output helpers.
#pragma once
#include <cstdint>
#include <string>

namespace json {

inline constexpr char kHex[] = "0123456789abcdef";

// Appends `s` as a quoted JSON string. Only `"`, `\` and bytes < 0x20 are escaped; other bytes (UTF-8) pass through.
inline void str(std::string &o, const char *s, size_t n) {
    o.push_back('"');
    size_t run = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char ch = static_cast<unsigned char>(s[i]);
        if (ch >= 0x20 && ch != '"' && ch != '\\') continue;
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
