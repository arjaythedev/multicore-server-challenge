#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace conduit {

// Minimal JSON writer that appends straight into the response string.
class JsonOut {
public:
    JsonOut() { s_.reserve(1024); }

    void Raw(std::string_view v) { s_.append(v); }
    void Str(std::string_view v);
    void OptStr(const std::optional<std::string_view>& v) {
        if (v) {
            Str(*v);
        } else {
            s_.append("null");
        }
    }
    void Int(std::int64_t v);
    void Bool(bool v) { s_.append(v ? "true" : "false"); }
    // RFC 3339 UTC with exactly 3 fractional digits (truncated).
    void Time(std::chrono::system_clock::time_point tp);

    std::string& Get() { return s_; }

private:
    std::string s_;
};

// Base64url without padding.
std::string Base64UrlEncode(std::string_view in);
bool Base64UrlDecode(std::string_view in, std::string& out);

// Only ASCII digits (no sign, no spaces), fitting in int64.
bool ParseUint(std::string_view s, std::int64_t& out);

}  // namespace conduit
