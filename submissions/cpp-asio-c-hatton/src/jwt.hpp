// HS256 JWTs: HMAC-SHA256 with the key pads hashed once at startup, and a verifier with golang-jwt's rules
// (alg must be HS256, exp required and in the future, nbf honoured, sub a decimal string).
#pragma once
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/crypto.h>
#include <openssl/sha.h>

#include <boost/json.hpp>
#include <chrono>
#include <string>
#include <string_view>

#include "util.hpp"

class Jwt {
 public:
  explicit Jwt(std::string_view key) {
    unsigned char k[64] = {0};
    if (key.size() > 64) {
      SHA256(reinterpret_cast<const unsigned char*>(key.data()), key.size(), k);
    } else {
      std::memcpy(k, key.data(), key.size());
    }
    unsigned char ipad[64], opad[64];
    for (int i = 0; i < 64; ++i) {
      ipad[i] = k[i] ^ 0x36;
      opad[i] = k[i] ^ 0x5c;
    }
    SHA256_Init(&inner_);
    SHA256_Update(&inner_, ipad, 64);
    SHA256_Init(&outer_);
    SHA256_Update(&outer_, opad, 64);
  }

  void mac(const void* d, size_t n, unsigned char out[32]) const {
    SHA256_CTX c = inner_;
    SHA256_Update(&c, d, n);
    unsigned char ih[32];
    SHA256_Final(ih, &c);
    c = outer_;
    SHA256_Update(&c, ih, 32);
    SHA256_Final(out, &c);
  }

  static double now() {
    return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
  }

  // {"alg":"HS256","typ":"JWT"} . {"sub":"<id>","iat":now,"exp":now+30d} . sig
  std::string issue(int64_t id) const {
    int64_t t = int64_t(now());
    std::string payload = "{\"sub\":\"";
    json_int(payload, id);
    payload += "\",\"iat\":";
    json_int(payload, t);
    payload += ",\"exp\":";
    json_int(payload, t + 30LL * 24 * 3600);
    payload += '}';
    std::string tok = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.";
    b64url_encode(tok, reinterpret_cast<const unsigned char*>(payload.data()), payload.size());
    unsigned char sig[32];
    mac(tok.data(), tok.size(), sig);
    tok.push_back('.');
    b64url_encode(tok, sig, 32);
    return tok;
  }

  // Returns the user id (> 0) for a valid token, else 0.
  int64_t verify(std::string_view tok) const {
    size_t d1 = tok.find('.');
    if (d1 == std::string_view::npos) return 0;
    size_t d2 = tok.find('.', d1 + 1);
    if (d2 == std::string_view::npos || tok.find('.', d2 + 1) != std::string_view::npos) return 0;
    std::string_view hs = tok.substr(0, d1), ps = tok.substr(d1 + 1, d2 - d1 - 1), ss = tok.substr(d2 + 1);

    unsigned char sig[64];
    size_t sn;
    if (!b64url_decode(ss, sig, sizeof sig, sn) || sn != 32) return 0;
    unsigned char want[32];
    mac(tok.data(), d2, want);
    if (CRYPTO_memcmp(sig, want, 32) != 0) return 0;

    unsigned char buf[1024];
    size_t n;
    unsigned char storage[4096];
    {
      if (!b64url_decode(hs, buf, sizeof buf, n)) return 0;
      boost::json::monotonic_resource mr(storage, sizeof storage);
      boost::system::error_code ec;
      boost::json::value h = boost::json::parse(std::string_view(reinterpret_cast<char*>(buf), n), ec, &mr);
      if (ec || !h.is_object()) return 0;
      auto* alg = h.as_object().if_contains("alg");
      if (!alg || !alg->is_string() || alg->as_string() != "HS256") return 0;
    }
    if (!b64url_decode(ps, buf, sizeof buf, n)) return 0;
    boost::json::monotonic_resource mr(storage, sizeof storage);
    boost::system::error_code ec;
    boost::json::value p = boost::json::parse(std::string_view(reinterpret_cast<char*>(buf), n), ec, &mr);
    if (ec || !p.is_object()) return 0;
    const auto& o = p.as_object();
    double t = now();
    auto num = [](const boost::json::value& v, double& out) {
      if (v.is_int64()) out = double(v.as_int64());
      else if (v.is_uint64()) out = double(v.as_uint64());
      else if (v.is_double()) out = v.as_double();
      else return false;
      return true;
    };
    double exp;
    auto* e = o.if_contains("exp");
    if (!e || !num(*e, exp) || !(t < exp)) return 0;
    if (auto* nb = o.if_contains("nbf")) {
      double nbf;
      if (!num(*nb, nbf) || t < nbf) return 0;
    }
    if (auto* ia = o.if_contains("iat")) {
      double iat;
      if (!num(*ia, iat)) return 0;
    }
    auto* sub = o.if_contains("sub");
    if (!sub || !sub->is_string()) return 0;
    int64_t id;
    if (!parse_uint(std::string_view(sub->as_string()), id) || id <= 0) return 0;
    return id;
  }

 private:
  SHA256_CTX inner_, outer_;
};
