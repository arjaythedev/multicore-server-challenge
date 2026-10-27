// JWT HS256: signature, alg, exp (and nbf when present) checked on every request; nothing is remembered.
// HMAC-SHA256 with the key's inner and outer pad states computed once (the per-request work is the two hashes).
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/sha.h>
#include <json/json.h>

#include <chrono>
#include <cmath>

#include "common.h"

static SHA256_CTX g_inner, g_outer;

void jwtInit(const std::string &secret) {
  unsigned char key[64] = {0};
  if (secret.size() > 64) SHA256((const unsigned char *)secret.data(), secret.size(), key);
  else memcpy(key, secret.data(), secret.size());
  unsigned char ip[64], op[64];
  for (int i = 0; i < 64; i++) { ip[i] = key[i] ^ 0x36; op[i] = key[i] ^ 0x5c; }
  SHA256_Init(&g_inner); SHA256_Update(&g_inner, ip, 64);
  SHA256_Init(&g_outer); SHA256_Update(&g_outer, op, 64);
}

static void hmac(const char *p, size_t n, unsigned char out[32]) {
  SHA256_CTX c = g_inner;
  unsigned char d[32];
  SHA256_Update(&c, p, n);
  SHA256_Final(d, &c);
  c = g_outer;
  SHA256_Update(&c, d, 32);
  SHA256_Final(out, &c);
}

static const char B64U[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static void b64url(const unsigned char *p, size_t n, std::string &o) {
  size_t i = 0;
  for (; i + 3 <= n; i += 3) {
    uint32_t v = (p[i] << 16) | (p[i + 1] << 8) | p[i + 2];
    o.push_back(B64U[v >> 18]); o.push_back(B64U[(v >> 12) & 63]); o.push_back(B64U[(v >> 6) & 63]); o.push_back(B64U[v & 63]);
  }
  if (n - i == 1) {
    uint32_t v = p[i] << 16;
    o.push_back(B64U[v >> 18]); o.push_back(B64U[(v >> 12) & 63]);
  } else if (n - i == 2) {
    uint32_t v = (p[i] << 16) | (p[i + 1] << 8);
    o.push_back(B64U[v >> 18]); o.push_back(B64U[(v >> 12) & 63]); o.push_back(B64U[(v >> 6) & 63]);
  }
}

static int8_t DEC[256];
static bool decInit = [] {
  for (int i = 0; i < 256; i++) DEC[i] = -1;
  for (int i = 0; i < 64; i++) DEC[(unsigned char)B64U[i]] = (int8_t)i;
  // Node's base64url decoder also takes the standard alphabet
  DEC[(unsigned char)'+'] = 62; DEC[(unsigned char)'/'] = 63;
  return true;
}();

static bool unb64url(std::string_view s, std::string &o) {
  if (s.size() % 4 == 1) return false;
  uint32_t acc = 0;
  int bits = 0;
  for (unsigned char c : s) {
    int8_t d = DEC[c];
    if (d < 0) return false;
    acc = (acc << 6) | (uint32_t)d;
    bits += 6;
    if (bits >= 8) { bits -= 8; o.push_back((char)((acc >> bits) & 0xff)); }
  }
  return true;
}

static std::string g_hdr = [] { std::string o; std::string h = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"; b64url((const unsigned char *)h.data(), h.size(), o); return o; }();

static double nowSeconds() {
  return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
}

static bool parseJson(const std::string &s, Json::Value &v) {
  static thread_local std::unique_ptr<Json::CharReader> r = [] {
    Json::CharReaderBuilder b;
    Json::CharReaderBuilder::strictMode(&b.settings_);
    b.settings_["rejectDupKeys"] = false;
    b.settings_["strictRoot"] = false;
    return std::unique_ptr<Json::CharReader>(b.newCharReader());
  }();
  std::string err;
  return r->parse(s.data(), s.data() + s.size(), &v, &err);
}

// digits only, 1..18 of them, as JavaScript's /^[0-9]{1,18}$/ and +sub <= MAX_SAFE_INTEGER
static int64_t subId(std::string_view s) {
  if (s.empty() || s.size() > 18) return 0;
  int64_t id = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return 0;
    id = id * 10 + (c - '0');
  }
  return id > 0 && id <= 9007199254740991LL ? id : 0;
}

// The tokens this server issues: {"sub":"<digits>","iat":<digits>,"exp":<digits>}. Anything else goes through a
// full JSON parser with the same checks.
static bool fastClaims(const std::string &c, int64_t &id, double &exp) {
  static const char A[] = "{\"sub\":\"", B[] = "\",\"iat\":", C[] = ",\"exp\":";
  size_t p = 0;
  auto lit = [&](const char *x, size_t n) { if (c.compare(p, n, x) != 0) return false; p += n; return true; };
  auto digits = [&](int64_t &out, size_t maxn) {
    size_t s = p;
    int64_t v = 0;
    while (p < c.size() && c[p] >= '0' && c[p] <= '9' && p - s < maxn) { v = v * 10 + (c[p] - '0'); p++; }
    if (p == s || (p < c.size() && c[p] >= '0' && c[p] <= '9')) return false;
    out = v;
    return true;
  };
  int64_t sub, iat, e;
  if (!lit(A, sizeof A - 1)) return false;
  size_t s0 = p;
  if (!digits(sub, 18)) return false;
  if (subId(std::string_view(c).substr(s0, p - s0)) == 0) return false;
  if (!lit(B, sizeof B - 1) || !digits(iat, 15) || !lit(C, sizeof C - 1) || !digits(e, 15)) return false;
  if (p + 1 != c.size() || c[p] != '}') return false;
  id = sub;
  exp = (double)e;
  return true;
}

int64_t verifyToken(std::string_view tok) {
  size_t d1 = tok.find('.');
  if (d1 == std::string_view::npos || d1 == 0) return 0;
  size_t d2 = tok.find('.', d1 + 1);
  if (d2 == std::string_view::npos || tok.find('.', d2 + 1) != std::string_view::npos) return 0;
  if (d2 - d1 > 2048 || tok.size() - d2 != 44) return 0;
  std::string_view h = tok.substr(0, d1);
  if (h != g_hdr) {
    std::string hj;
    Json::Value hv;
    if (h.size() > 1024 || !unb64url(h, hj) || !parseJson(hj, hv) || !hv.isObject()) return 0;
    const Json::Value &alg = hv["alg"];
    if (!alg.isString() || alg.asString() != "HS256") return 0;
  }
  unsigned char mac[32];
  hmac(tok.data(), d2, mac);
  std::string want;
  want.reserve(44);
  b64url(mac, 32, want);
  unsigned diff = 0;
  for (int i = 0; i < 43; i++) diff |= (unsigned char)want[i] ^ (unsigned char)tok[d2 + 1 + i];
  if (diff != 0) return 0;
  std::string cj;
  if (!unb64url(tok.substr(d1 + 1, d2 - d1 - 1), cj)) return 0;
  double now = nowSeconds();
  int64_t id;
  double exp;
  if (fastClaims(cj, id, exp)) return exp > now ? id : 0;
  Json::Value cv;
  if (!parseJson(cj, cv) || !cv.isObject()) return 0;
  const Json::Value &e = cv["exp"];
  if (!e.isNumeric() || !(e.asDouble() > now)) return 0;
  if (cv.isMember("nbf")) {
    const Json::Value &nbf = cv["nbf"];
    if (!nbf.isNumeric() || nbf.asDouble() > now) return 0;
  }
  const Json::Value &sub = cv["sub"];
  if (!sub.isString()) return 0;
  return subId(sub.asString());
}

std::string issueToken(int64_t id) {
  int64_t now = (int64_t)std::floor(nowSeconds());
  std::string claims = "{\"sub\":\"" + std::to_string(id) + "\",\"iat\":" + std::to_string(now) + ",\"exp\":" + std::to_string(now + 30 * 24 * 3600) + "}";
  std::string t = g_hdr;
  t.push_back('.');
  b64url((const unsigned char *)claims.data(), claims.size(), t);
  unsigned char mac[32];
  hmac(t.data(), t.size(), mac);
  t.push_back('.');
  b64url(mac, 32, t);
  return t;
}
