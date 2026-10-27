#pragma once

#include <cstdint>
#include <string>
#include <string_view>

#include <openssl/sha.h>

namespace conduit {

// HS256 JWTs with {"sub": "<id>", "iat", "exp"} claims. The HMAC key pads are hashed once at startup.
class Jwt {
public:
    explicit Jwt(std::string_view secret);

    std::string Issue(std::int64_t user_id) const;
    // Returns the user id for a valid token (signature, alg HS256, exp, numeric string sub), else 0.
    std::int64_t Verify(std::string_view token) const;

private:
    std::string SignB64(std::string_view data) const;

    SHA256_CTX inner_{};
    SHA256_CTX outer_{};
};

// bcrypt, cost 10 (libxcrypt). Both are CPU heavy: call them on the bcrypt task processor.
std::string BcryptHash(std::string_view password);
bool BcryptCheck(std::string_view password, const std::string& hash);

}  // namespace conduit
