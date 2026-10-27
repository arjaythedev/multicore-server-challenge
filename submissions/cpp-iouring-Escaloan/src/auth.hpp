// JWT HS256 verification and issuing. Every request verifies its token from scratch (no verification cache).
// The HMAC key schedule (SHA-256 state after absorbing key^ipad and key^opad) is computed once from JWT_SECRET:
// that is key setup, not cached verification.
#pragma once
#include <cstdint>
#include <string_view>

namespace auth {

// Must be called once at startup, before any loop thread starts.
void init(std::string_view secret);

enum class TokenStatus : std::uint8_t { Ok, Invalid };

// Verifies `token` (the part after "Token "): three base64url parts, header alg == HS256, valid signature,
// payload with sub = decimal string of a positive int64 and a numeric exp > now. `now` is unix seconds.
TokenStatus verify(std::string_view token, std::int64_t now, std::int64_t& user_id);

// Writes a fresh token for user_id into out (needs kMaxTokenLen bytes); returns its length.
inline constexpr std::size_t kMaxTokenLen = 256;
std::size_t issue(std::int64_t user_id, std::int64_t now, char* out);

// base64url without padding (exposed for tests).
std::size_t b64url_encode(const unsigned char* in, std::size_t n, char* out);
// Returns decoded length or -1 on invalid input (padding is rejected, as in RFC 7515).
long b64url_decode(std::string_view in, unsigned char* out, std::size_t out_cap);

}  // namespace auth
