#include "auth.hpp"

#include <crypt.h>
#include <openssl/crypto.h>

#include <chrono>
#include <cstring>
#include <memory>
#include <stdexcept>

#include <userver/formats/json/value.hpp>
#include <userver/formats/json/serialize.hpp>

#include "util.hpp"

namespace conduit {

namespace {

namespace json = USERVER_NAMESPACE::formats::json;

// base64url('{"alg":"HS256","typ":"JWT"}'): the header every token we and golang-jwt issue has.
constexpr std::string_view kHeaderB64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
constexpr std::int64_t kTokenTtl = 30 * 24 * 3600;

std::int64_t NowSeconds() {
    return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch())
        .count();
}

bool HeaderIsHs256(std::string_view b64) {
    if (b64 == kHeaderB64) return true;
    std::string raw;
    if (!Base64UrlDecode(b64, raw)) return false;
    try {
        const auto h = json::FromString(raw);
        if (!h.IsObject()) return false;
        const auto alg = h["alg"];
        return alg.IsString() && alg.As<std::string>() == "HS256";
    } catch (const std::exception&) {
        return false;
    }
}

bool IsNumber(const json::Value& v) { return v.IsInt64() || v.IsUInt64() || v.IsDouble(); }

crypt_data& ThreadCryptData() {
    // crypt_data is ~32 KB: keep one per OS thread instead of on the (small) coroutine stack.
    // crypt_rn never yields, so a coroutine can't be switched out while using it.
    thread_local auto data = std::make_unique<crypt_data>();
    return *data;
}

}  // namespace

Jwt::Jwt(std::string_view secret) {
    unsigned char key[SHA256_CBLOCK] = {};
    if (secret.size() > SHA256_CBLOCK) {
        SHA256(reinterpret_cast<const unsigned char*>(secret.data()), secret.size(), key);
    } else {
        std::memcpy(key, secret.data(), secret.size());
    }
    unsigned char ipad[SHA256_CBLOCK];
    unsigned char opad[SHA256_CBLOCK];
    for (int i = 0; i < SHA256_CBLOCK; ++i) {
        ipad[i] = key[i] ^ 0x36;
        opad[i] = key[i] ^ 0x5c;
    }
    SHA256_Init(&inner_);
    SHA256_Update(&inner_, ipad, sizeof(ipad));
    SHA256_Init(&outer_);
    SHA256_Update(&outer_, opad, sizeof(opad));
}

std::string Jwt::SignB64(std::string_view data) const {
    unsigned char inner_hash[SHA256_DIGEST_LENGTH];
    unsigned char mac[SHA256_DIGEST_LENGTH];
    SHA256_CTX ctx = inner_;
    SHA256_Update(&ctx, data.data(), data.size());
    SHA256_Final(inner_hash, &ctx);
    ctx = outer_;
    SHA256_Update(&ctx, inner_hash, sizeof(inner_hash));
    SHA256_Final(mac, &ctx);
    return Base64UrlEncode(std::string_view(reinterpret_cast<const char*>(mac), sizeof(mac)));
}

std::string Jwt::Issue(std::int64_t user_id) const {
    const auto now = NowSeconds();
    std::string payload = "{\"sub\":\"" + std::to_string(user_id) + "\",\"iat\":" + std::to_string(now) +
                          ",\"exp\":" + std::to_string(now + kTokenTtl) + "}";
    std::string token;
    token.reserve(200);
    token.append(kHeaderB64);
    token.push_back('.');
    token.append(Base64UrlEncode(payload));
    const auto sig = SignB64(token);
    token.push_back('.');
    token.append(sig);
    return token;
}

std::int64_t Jwt::Verify(std::string_view token) const {
    const auto dot1 = token.find('.');
    if (dot1 == std::string_view::npos) return 0;
    const auto dot2 = token.find('.', dot1 + 1);
    if (dot2 == std::string_view::npos || token.find('.', dot2 + 1) != std::string_view::npos) return 0;

    if (!HeaderIsHs256(token.substr(0, dot1))) return 0;

    const auto sig = token.substr(dot2 + 1);
    const auto expected = SignB64(token.substr(0, dot2));
    if (sig.size() != expected.size() || CRYPTO_memcmp(sig.data(), expected.data(), sig.size()) != 0) return 0;

    std::string payload;
    if (!Base64UrlDecode(token.substr(dot1 + 1, dot2 - dot1 - 1), payload)) return 0;
    try {
        const auto claims = json::FromString(payload);
        if (!claims.IsObject()) return 0;
        const auto now = NowSeconds();

        const auto exp = claims["exp"];
        if (!IsNumber(exp) || !(static_cast<double>(now) < exp.As<double>())) return 0;
        const auto nbf = claims["nbf"];
        if (!nbf.IsMissing() && (!IsNumber(nbf) || static_cast<double>(now) < nbf.As<double>())) return 0;

        const auto sub = claims["sub"];
        if (!sub.IsString()) return 0;
        std::int64_t id = 0;
        if (!ParseUint(sub.As<std::string>(), id) || id <= 0) return 0;
        return id;
    } catch (const std::exception&) {
        return 0;
    }
}

std::string BcryptHash(std::string_view password) {
    char salt[CRYPT_GENSALT_OUTPUT_SIZE];
    if (!crypt_gensalt_rn("$2b$", 10, nullptr, 0, salt, sizeof(salt))) {
        throw std::runtime_error("crypt_gensalt_rn failed");
    }
    const std::string pw(password);
    auto& data = ThreadCryptData();
    const char* out = crypt_rn(pw.c_str(), salt, &data, sizeof(data));
    if (!out || out[0] == '*') throw std::runtime_error("crypt_rn failed");
    return out;
}

bool BcryptCheck(std::string_view password, const std::string& hash) {
    if (password.size() > 72) return false;
    const std::string pw(password);
    auto& data = ThreadCryptData();
    const char* out = crypt_rn(pw.c_str(), hash.c_str(), &data, sizeof(data));
    if (!out || out[0] == '*') return false;
    const auto len = std::strlen(out);
    return len == hash.size() && CRYPTO_memcmp(out, hash.data(), len) == 0;
}

}  // namespace conduit
