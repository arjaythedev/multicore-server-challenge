#include "auth.hpp"

#include <openssl/crypto.h>
#include <openssl/sha.h>

#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include "json_read.hpp"
#include "util.hpp"

// The SHA256_* functions are deprecated in OpenSSL 3 in favour of EVP, but they are still exported and avoid
// EVP's per-call context allocation and dispatch. Two SHA-256 blocks per verification is all the work there is.
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

namespace auth {
namespace {

SHA256_CTX g_inner;  // state after absorbing (key ^ ipad)
SHA256_CTX g_outer;  // state after absorbing (key ^ opad)
bool g_ready = false;

// base64url("{"alg":"HS256","typ":"JWT"}"), the header every issued token carries.
constexpr std::string_view kIssuedHeader = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

void hmac(const char* data, std::size_t n, unsigned char out[32]) {
  SHA256_CTX c = g_inner;
  SHA256_Update(&c, data, n);
  unsigned char inner[32];
  SHA256_Final(inner, &c);
  c = g_outer;
  SHA256_Update(&c, inner, 32);
  SHA256_Final(out, &c);
}

constexpr signed char kB64Rev[256] = {
#define X -1
    X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X,
    X, X, X, X, X, X, X, X, X, X, X, X, X, 62, X, X, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, X, X, X, X, X, X,
    X, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, X, X, X, X, 63,
    X, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, X, X, X, X, X,
    X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X,
    X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X,
    X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X,
    X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X, X,
#undef X
};

// Parses a JSON number as a double; only for exp/nbf, which golang-jwt reads as float64 seconds.
bool number_value(const json::Node* n, double& out) {
  if (!n || n->type != json::Type::Number) return false;
  char tmp[64];
  if (n->len >= sizeof tmp) return false;
  std::memcpy(tmp, n->str, n->len);
  tmp[n->len] = 0;
  char* e;
  out = std::strtod(tmp, &e);
  return e == tmp + n->len && std::isfinite(out);
}

thread_local json::Doc t_doc;

}  // namespace

void init(std::string_view secret) {
  unsigned char key[64] = {};
  if (secret.size() > 64) {
    SHA256(reinterpret_cast<const unsigned char*>(secret.data()), secret.size(), key);
  } else {
    std::memcpy(key, secret.data(), secret.size());
  }
  unsigned char pad[64];
  for (int i = 0; i < 64; ++i) pad[i] = key[i] ^ 0x36;
  SHA256_Init(&g_inner);
  SHA256_Update(&g_inner, pad, 64);
  for (int i = 0; i < 64; ++i) pad[i] = key[i] ^ 0x5c;
  SHA256_Init(&g_outer);
  SHA256_Update(&g_outer, pad, 64);
  OPENSSL_cleanse(key, sizeof key);
  OPENSSL_cleanse(pad, sizeof pad);
  g_ready = true;
}

std::size_t b64url_encode(const unsigned char* in, std::size_t n, char* out) {
  static constexpr char kAlpha[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::size_t o = 0, i = 0;
  for (; i + 3 <= n; i += 3) {
    std::uint32_t v = (std::uint32_t(in[i]) << 16) | (std::uint32_t(in[i + 1]) << 8) | in[i + 2];
    out[o++] = kAlpha[v >> 18];
    out[o++] = kAlpha[(v >> 12) & 63];
    out[o++] = kAlpha[(v >> 6) & 63];
    out[o++] = kAlpha[v & 63];
  }
  if (n - i == 1) {
    std::uint32_t v = std::uint32_t(in[i]) << 16;
    out[o++] = kAlpha[v >> 18];
    out[o++] = kAlpha[(v >> 12) & 63];
  } else if (n - i == 2) {
    std::uint32_t v = (std::uint32_t(in[i]) << 16) | (std::uint32_t(in[i + 1]) << 8);
    out[o++] = kAlpha[v >> 18];
    out[o++] = kAlpha[(v >> 12) & 63];
    out[o++] = kAlpha[(v >> 6) & 63];
  }
  return o;
}

long b64url_decode(std::string_view in, unsigned char* out, std::size_t out_cap) {
  std::size_t n = in.size();
  if (n % 4 == 1) return -1;
  std::size_t need = n / 4 * 3 + (n % 4 ? n % 4 - 1 : 0);
  if (need > out_cap) return -1;
  std::size_t o = 0, i = 0;
  for (; i + 4 <= n; i += 4) {
    int a = kB64Rev[static_cast<unsigned char>(in[i])], b = kB64Rev[static_cast<unsigned char>(in[i + 1])];
    int c = kB64Rev[static_cast<unsigned char>(in[i + 2])], d = kB64Rev[static_cast<unsigned char>(in[i + 3])];
    if ((a | b | c | d) < 0) return -1;
    std::uint32_t v = (std::uint32_t(a) << 18) | (std::uint32_t(b) << 12) | (std::uint32_t(c) << 6) | std::uint32_t(d);
    out[o++] = static_cast<unsigned char>(v >> 16);
    out[o++] = static_cast<unsigned char>(v >> 8);
    out[o++] = static_cast<unsigned char>(v);
  }
  std::size_t rem = n - i;
  if (rem >= 2) {
    int a = kB64Rev[static_cast<unsigned char>(in[i])], b = kB64Rev[static_cast<unsigned char>(in[i + 1])];
    int c = rem == 3 ? kB64Rev[static_cast<unsigned char>(in[i + 2])] : 0;
    if ((a | b | c) < 0) return -1;
    std::uint32_t v = (std::uint32_t(a) << 18) | (std::uint32_t(b) << 12) | (std::uint32_t(c) << 6);
    out[o++] = static_cast<unsigned char>(v >> 16);
    if (rem == 3) out[o++] = static_cast<unsigned char>(v >> 8);
  }
  return long(o);
}

TokenStatus verify(std::string_view token, std::int64_t now, std::int64_t& user_id) {
  std::size_t d1 = token.find('.');
  if (d1 == std::string_view::npos) return TokenStatus::Invalid;
  std::size_t d2 = token.find('.', d1 + 1);
  if (d2 == std::string_view::npos || token.find('.', d2 + 1) != std::string_view::npos) return TokenStatus::Invalid;
  std::string_view h64 = token.substr(0, d1), p64 = token.substr(d1 + 1, d2 - d1 - 1), s64 = token.substr(d2 + 1);
  if (h64.size() > 512 || p64.size() > 2048) return TokenStatus::Invalid;

  // Signature first: it is the cheapest rejection for forged tokens and needs no parsing.
  unsigned char sig[48];
  if (b64url_decode(s64, sig, sizeof sig) != 32) return TokenStatus::Invalid;
  unsigned char mac[32];
  hmac(token.data(), d2, mac);
  if (CRYPTO_memcmp(sig, mac, 32) != 0) return TokenStatus::Invalid;

  // Header: alg must be exactly HS256. Fast path for the header every issued/minted token uses.
  if (h64 != kIssuedHeader) {
    char hbuf[400];
    long hl = b64url_decode(h64, reinterpret_cast<unsigned char*>(hbuf), sizeof hbuf);
    if (hl < 0 || !t_doc.parse(hbuf, std::size_t(hl))) return TokenStatus::Invalid;
    const json::Node* alg = t_doc.get(t_doc.root(), "alg");
    if (!alg || alg->type != json::Type::String || json::as_string(alg) != "HS256") return TokenStatus::Invalid;
  }

  // Payload: sub (decimal string of a positive id), exp (number, required, > now), nbf (if present, <= now).
  char pbuf[1600];
  long pl = b64url_decode(p64, reinterpret_cast<unsigned char*>(pbuf), sizeof pbuf);
  if (pl < 0 || !t_doc.parse(pbuf, std::size_t(pl))) return TokenStatus::Invalid;
  const json::Node* root = t_doc.root();
  if (!root || root->type != json::Type::Object) return TokenStatus::Invalid;
  double exp;
  if (!number_value(t_doc.get(root, "exp"), exp)) return TokenStatus::Invalid;
  if (!(double(now) < exp)) return TokenStatus::Invalid;
  if (const json::Node* nbf = t_doc.get(root, "nbf"); nbf && nbf->type != json::Type::Null) {
    double v;
    if (!number_value(nbf, v) || double(now) < v) return TokenStatus::Invalid;
  }
  if (const json::Node* iat = t_doc.get(root, "iat"); iat && iat->type != json::Type::Null) {
    double v;
    if (!number_value(iat, v)) return TokenStatus::Invalid;  // wrong type fails claim decoding in golang-jwt
  }
  const json::Node* sub = t_doc.get(root, "sub");
  if (!sub || sub->type != json::Type::String) return TokenStatus::Invalid;
  std::int64_t id;
  if (!util::parse_uint(json::as_string(sub), id) || id <= 0) return TokenStatus::Invalid;
  user_id = id;
  return TokenStatus::Ok;
}

std::size_t issue(std::int64_t user_id, std::int64_t now, char* out) {
  char payload[96];
  int pn = std::snprintf(payload, sizeof payload, "{\"sub\":\"%lld\",\"iat\":%lld,\"exp\":%lld}", (long long)user_id,
                         (long long)now, (long long)(now + 30LL * 24 * 3600));
  std::size_t o = 0;
  std::memcpy(out, kIssuedHeader.data(), kIssuedHeader.size());
  o += kIssuedHeader.size();
  out[o++] = '.';
  o += b64url_encode(reinterpret_cast<const unsigned char*>(payload), std::size_t(pn), out + o);
  unsigned char mac[32];
  hmac(out, o, mac);
  out[o++] = '.';
  o += b64url_encode(mac, 32, out + o);
  return o;
}

}  // namespace auth
