// HS256 JWT with precomputed HMAC inner/outer SHA-256 states. Read-only after init, so safe to share between workers.
#pragma once
#include <openssl/sha.h>

#include <cstdint>
#include <string>
#include <string_view>

struct Jwt {
    void init(std::string_view secret);
    // Token for user `sub`, valid for 30 days from `now`.
    std::string sign(int64_t sub, int64_t now) const;
    // Verifies alg, signature, `sub` and `exp` (against `now`). On success returns true and sets `sub`.
    bool verify(std::string_view token, int64_t now, int64_t &sub) const;

  private:
    void mac(std::string_view data, unsigned char out[32]) const;
    SHA256_CTX inner_, outer_;
};

extern Jwt g_jwt;
