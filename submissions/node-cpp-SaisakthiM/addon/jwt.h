// HS256 JWT verify/sign, no caching: every call recomputes the HMAC and re-checks alg and exp.
#pragma once

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

namespace jwt {

inline const char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

inline std::string b64url_encode(const unsigned char* d, size_t n) {
  std::string out;
  out.reserve((n + 2) / 3 * 4);
  size_t i = 0;
  for (; i + 2 < n; i += 3) {
    const uint32_t v = (uint32_t(d[i]) << 16) | (uint32_t(d[i + 1]) << 8) | uint32_t(d[i + 2]);
    out += kB64[(v >> 18) & 63];
    out += kB64[(v >> 12) & 63];
    out += kB64[(v >> 6) & 63];
    out += kB64[v & 63];
  }
  if (n - i == 1) {
    const uint32_t v = uint32_t(d[i]) << 16;
    out += kB64[(v >> 18) & 63];
    out += kB64[(v >> 12) & 63];
  } else if (n - i == 2) {
    const uint32_t v = (uint32_t(d[i]) << 16) | (uint32_t(d[i + 1]) << 8);
    out += kB64[(v >> 18) & 63];
    out += kB64[(v >> 12) & 63];
    out += kB64[(v >> 6) & 63];
  }
  return out;
}

inline int b64_value(unsigned char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '-') return 62;
  if (c == '_') return 63;
  return -1;
}

// Unpadded base64url only. Any other character (including '=' and '+' '/') is rejected.
inline bool b64url_decode(const char* s, size_t n, std::string& out) {
  if (n % 4 == 1) return false;
  out.clear();
  out.reserve(n * 3 / 4 + 3);
  uint32_t acc = 0;
  int bits = 0;
  for (size_t i = 0; i < n; ++i) {
    const int v = b64_value(static_cast<unsigned char>(s[i]));
    if (v < 0) return false;
    acc = (acc << 6) | uint32_t(v);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += static_cast<char>((acc >> bits) & 0xff);
    }
  }
  return true;
}

inline bool hmac_sha256(const std::string& key, const char* data, size_t n, unsigned char out[32]) {
  unsigned int len = 0;
  const unsigned char* r = HMAC(EVP_sha256(), key.data(), static_cast<int>(key.size()),
                                reinterpret_cast<const unsigned char*>(data), n, out, &len);
  return r != nullptr && len == 32;
}

// ---- tiny JSON object scanner: just enough to read "alg", "sub" and "exp" ----

struct Scanner {
  const char* p;
  const char* e;

  void ws() {
    while (p < e && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) ++p;
  }

  // at an opening quote; decodes escapes (non-ASCII \u escapes become '?', which is fine for our keys/values)
  bool str(std::string& out) {
    if (p >= e || *p != '"') return false;
    ++p;
    out.clear();
    while (p < e) {
      const unsigned char c = static_cast<unsigned char>(*p++);
      if (c == '"') return true;
      if (c == '\\') {
        if (p >= e) return false;
        const char x = *p++;
        switch (x) {
          case '"': out += '"'; break;
          case '\\': out += '\\'; break;
          case '/': out += '/'; break;
          case 'b': out += '\b'; break;
          case 'f': out += '\f'; break;
          case 'n': out += '\n'; break;
          case 'r': out += '\r'; break;
          case 't': out += '\t'; break;
          case 'u': {
            if (e - p < 4) return false;
            unsigned v = 0;
            for (int i = 0; i < 4; ++i) {
              const char h = *p++;
              v <<= 4;
              if (h >= '0' && h <= '9') v |= unsigned(h - '0');
              else if (h >= 'a' && h <= 'f') v |= unsigned(h - 'a' + 10);
              else if (h >= 'A' && h <= 'F') v |= unsigned(h - 'A' + 10);
              else return false;
            }
            out += v < 0x80 ? static_cast<char>(v) : '?';
            break;
          }
          default: return false;
        }
      } else if (c < 0x20) {
        return false;
      } else {
        out += static_cast<char>(c);
      }
    }
    return false;
  }

  bool skip_value(int depth = 0) {
    if (depth > 32) return false;
    ws();
    if (p >= e) return false;
    const char c = *p;
    if (c == '"') {
      std::string t;
      return str(t);
    }
    if (c == '{') {
      ++p;
      ws();
      if (p < e && *p == '}') {
        ++p;
        return true;
      }
      for (;;) {
        ws();
        std::string k;
        if (!str(k)) return false;
        ws();
        if (p >= e || *p != ':') return false;
        ++p;
        if (!skip_value(depth + 1)) return false;
        ws();
        if (p >= e) return false;
        if (*p == ',') { ++p; continue; }
        if (*p == '}') { ++p; return true; }
        return false;
      }
    }
    if (c == '[') {
      ++p;
      ws();
      if (p < e && *p == ']') {
        ++p;
        return true;
      }
      for (;;) {
        if (!skip_value(depth + 1)) return false;
        ws();
        if (p >= e) return false;
        if (*p == ',') { ++p; continue; }
        if (*p == ']') { ++p; return true; }
        return false;
      }
    }
    const char* s = p;  // number / true / false / null
    while (p < e && *p != ',' && *p != '}' && *p != ']' && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') ++p;
    return p > s;
  }
};

struct Fields {
  std::string alg, sub;
  bool alg_str = false, sub_str = false, exp_num = false;
  double exp = 0;
};

inline bool parse_fields(const std::string& js, Fields& f) {
  Scanner s{js.data(), js.data() + js.size()};
  s.ws();
  if (s.p >= s.e || *s.p != '{') return false;
  ++s.p;
  s.ws();
  if (s.p < s.e && *s.p == '}') {
    ++s.p;
    s.ws();
    return s.p == s.e;
  }
  for (;;) {
    s.ws();
    std::string key;
    if (!s.str(key)) return false;
    s.ws();
    if (s.p >= s.e || *s.p != ':') return false;
    ++s.p;
    s.ws();
    if (s.p >= s.e) return false;
    if (key == "alg") {
      f.alg_str = false;
      if (*s.p == '"') {
        if (!s.str(f.alg)) return false;
        f.alg_str = true;
      } else if (!s.skip_value()) {
        return false;
      }
    } else if (key == "sub") {
      f.sub_str = false;
      if (*s.p == '"') {
        if (!s.str(f.sub)) return false;
        f.sub_str = true;
      } else if (!s.skip_value()) {
        return false;
      }
    } else if (key == "exp") {
      f.exp_num = false;
      if (*s.p == '-' || (*s.p >= '0' && *s.p <= '9')) {
        char* endp = nullptr;
        const double v = std::strtod(s.p, &endp);
        if (endp == s.p) return false;
        s.p = endp;
        f.exp = v;
        f.exp_num = true;
      } else if (!s.skip_value()) {
        return false;
      }
    } else if (!s.skip_value()) {
      return false;
    }
    s.ws();
    if (s.p >= s.e) return false;
    if (*s.p == ',') { ++s.p; continue; }
    if (*s.p == '}') { ++s.p; break; }
    return false;
  }
  s.ws();
  return s.p == s.e;
}

// Returns the user id (> 0) of a valid token, or 0 when anything is wrong: shape, signature, alg != HS256,
// missing/expired exp, sub not a decimal string.
inline int64_t verify(const std::string& secret, const char* tok, size_t n) {
  if (n < 10 || n > 1024) return 0;
  const char* d1 = static_cast<const char*>(std::memchr(tok, '.', n));
  if (d1 == nullptr) return 0;
  const char* d2 = static_cast<const char*>(std::memchr(d1 + 1, '.', n - size_t(d1 + 1 - tok)));
  if (d2 == nullptr) return 0;
  if (std::memchr(d2 + 1, '.', n - size_t(d2 + 1 - tok)) != nullptr) return 0;  // exactly three parts

  unsigned char mac[32];
  if (!hmac_sha256(secret, tok, size_t(d2 - tok), mac)) return 0;
  std::string sig;
  if (!b64url_decode(d2 + 1, size_t(tok + n - (d2 + 1)), sig) || sig.size() != 32) return 0;
  if (CRYPTO_memcmp(mac, sig.data(), 32) != 0) return 0;

  std::string header, payload;
  if (!b64url_decode(tok, size_t(d1 - tok), header)) return 0;
  if (!b64url_decode(d1 + 1, size_t(d2 - (d1 + 1)), payload)) return 0;

  Fields hf, pf;
  if (!parse_fields(header, hf) || !hf.alg_str || hf.alg != "HS256") return 0;
  if (!parse_fields(payload, pf) || !pf.sub_str || !pf.exp_num) return 0;
  if (!(pf.exp > static_cast<double>(std::time(nullptr)))) return 0;

  if (pf.sub.empty() || pf.sub.size() > 18) return 0;
  int64_t id = 0;
  for (char c : pf.sub) {
    if (c < '0' || c > '9') return 0;
    id = id * 10 + (c - '0');
  }
  return id > 0 ? id : 0;
}

inline std::string sign(const std::string& secret, int64_t id) {
  const long long now = static_cast<long long>(std::time(nullptr));
  const std::string header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
  const std::string payload = "{\"sub\":\"" + std::to_string(id) + "\",\"iat\":" + std::to_string(now) +
                              ",\"exp\":" + std::to_string(now + 30LL * 24 * 3600) + "}";
  std::string s = b64url_encode(reinterpret_cast<const unsigned char*>(header.data()), header.size());
  s += '.';
  s += b64url_encode(reinterpret_cast<const unsigned char*>(payload.data()), payload.size());
  unsigned char mac[32];
  hmac_sha256(secret, s.data(), s.size(), mac);
  s += '.';
  s += b64url_encode(mac, 32);
  return s;
}

}  // namespace jwt
