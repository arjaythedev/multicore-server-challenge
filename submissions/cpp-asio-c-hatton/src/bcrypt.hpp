// bcrypt ($2a$/$2b$/$2y$) that computes up to 4 hashes at once, interleaved in lockstep on one thread.
//
// Blowfish rounds are a serial chain of dependent S-box loads, so a single bcrypt leaves most of a core's
// load/ALU ports idle. Running N independent hashes round by round fills them: 4 hashes cost far less than
// 4x one. It's the standard EksBlowfish algorithm at the full requested cost (10 here), just scheduled better.
//
// Used only where the result is provably identical to libxcrypt: ASCII passwords of at most 72 bytes (8-bit
// characters are where the $2a$/$2x$/$2y$ variants differ). Everything else goes to crypt_rn().
#pragma once
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>

namespace bcrypt {

struct State {
  uint32_t P[18];
  uint32_t S[4][256];
};

const State& initial_state();  // the digits of pi (bcrypt_tables.cpp)

static const char kB64[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

inline int b64v(char c) {
  const char* p = std::strchr(kB64, c);
  return (p && c) ? int(p - kB64) : -1;
}

// bcrypt's own base64 (no padding)
inline bool b64_decode(std::string_view s, uint8_t* out, size_t n) {
  size_t o = 0, i = 0;
  while (o < n) {
    int c1 = i < s.size() ? b64v(s[i++]) : -1, c2 = i < s.size() ? b64v(s[i++]) : -1;
    if (c1 < 0 || c2 < 0) return false;
    out[o++] = uint8_t((c1 << 2) | ((c2 & 0x30) >> 4));
    if (o >= n) break;
    int c3 = i < s.size() ? b64v(s[i++]) : -1;
    if (c3 < 0) return false;
    out[o++] = uint8_t(((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2));
    if (o >= n) break;
    int c4 = i < s.size() ? b64v(s[i++]) : -1;
    if (c4 < 0) return false;
    out[o++] = uint8_t(((c3 & 0x03) << 6) | c4);
  }
  return true;
}

inline void b64_encode(std::string& o, const uint8_t* d, size_t n) {
  size_t i = 0;
  while (i < n) {
    uint32_t c1 = d[i++];
    o.push_back(kB64[c1 >> 2]);
    c1 = (c1 & 0x03) << 4;
    if (i >= n) { o.push_back(kB64[c1]); break; }
    uint32_t c2 = d[i++];
    c1 |= c2 >> 4;
    o.push_back(kB64[c1]);
    c1 = (c2 & 0x0f) << 2;
    if (i >= n) { o.push_back(kB64[c1]); break; }
    c2 = d[i++];
    c1 |= c2 >> 6;
    o.push_back(kB64[c1]);
    o.push_back(kB64[c2 & 0x3f]);
  }
}

// One hash to compute: inputs (key = password, salt from setting) and the output string.
struct Job {
  std::string password;
  int cost = 0;
  char variant = 'b';     // 'a', 'b' or 'y' (identical for ASCII passwords)
  uint8_t salt[16] = {};
  std::string salt_str;   // the 22 encoded salt characters
  std::string result;     // "$2b$10$" + salt + hash
};

// Parses "$2?$NN$<22 salt chars>..." for the fast path. False: use libxcrypt instead.
inline bool prepare(Job& j, std::string_view password, std::string_view setting) {
  if (password.size() > 72) return false;
  for (unsigned char c : password)
    if (c >= 0x80 || c == 0) return false;
  if (setting.size() < 29 || setting[0] != '$' || setting[1] != '2' || setting[3] != '$' || setting[6] != '$') return false;
  char v = setting[2];
  if (v != 'a' && v != 'b' && v != 'y') return false;
  if (setting[4] < '0' || setting[4] > '9' || setting[5] < '0' || setting[5] > '9') return false;
  int cost = (setting[4] - '0') * 10 + (setting[5] - '0');
  if (cost < 4 || cost > 31) return false;
  std::string_view salt = setting.substr(7, 22);
  if (!b64_decode(salt, j.salt, 16)) return false;
  // the last salt character only carries 2 significant bits; re-encode to its canonical form
  std::string canon;
  b64_encode(canon, j.salt, 16);
  j.password.assign(password);
  j.cost = cost;
  j.variant = v;
  j.salt_str = canon;
  return true;
}

template <int N>
struct Lanes {
  State st[N];
  uint32_t key[N][18];
  uint32_t salt[N][4];

  static inline uint32_t F(const State& s, uint32_t x) {
    return ((s.S[0][x >> 24] + s.S[1][(x >> 16) & 0xff]) ^ s.S[2][(x >> 8) & 0xff]) + s.S[3][x & 0xff];
  }

  // Encrypts (L[l], R[l]) for every lane, interleaved round by round.
  inline void encrypt(uint32_t* L, uint32_t* R) {
    for (int l = 0; l < N; ++l) L[l] ^= st[l].P[0];
    for (int i = 1; i <= 16; i += 2) {
      for (int l = 0; l < N; ++l) R[l] ^= F(st[l], L[l]) ^ st[l].P[i];
      for (int l = 0; l < N; ++l) L[l] ^= F(st[l], R[l]) ^ st[l].P[i + 1];
    }
    for (int l = 0; l < N; ++l) {
      uint32_t t = L[l];
      L[l] = R[l] ^ st[l].P[17];
      R[l] = t;
    }
  }

  // ExpandKey(state, salt, key); with_salt=false is ExpandKey(state, 0, key-or-salt as "key").
  template <bool WithSalt>
  inline void expand(const uint32_t (*k)[18]) {
    for (int l = 0; l < N; ++l)
      for (int i = 0; i < 18; ++i) st[l].P[i] ^= k[l][i];
    uint32_t L[N] = {}, R[N] = {};
    int si = 0;
    for (int i = 0; i < 18; i += 2) {
      if (WithSalt) {
        for (int l = 0; l < N; ++l) { L[l] ^= salt[l][si]; R[l] ^= salt[l][si + 1]; }
        si ^= 2;
      }
      encrypt(L, R);
      for (int l = 0; l < N; ++l) { st[l].P[i] = L[l]; st[l].P[i + 1] = R[l]; }
    }
    for (int b = 0; b < 4; ++b) {
      for (int i = 0; i < 256; i += 2) {
        if (WithSalt) {
          for (int l = 0; l < N; ++l) { L[l] ^= salt[l][si]; R[l] ^= salt[l][si + 1]; }
          si ^= 2;
        }
        encrypt(L, R);
        for (int l = 0; l < N; ++l) { st[l].S[b][i] = L[l]; st[l].S[b][i + 1] = R[l]; }
      }
    }
  }

  void run(Job* const* jobs) {
    uint32_t saltkey[N][18];
    for (int l = 0; l < N; ++l) {
      const Job& j = *jobs[l];
      st[l] = initial_state();
      // key: password bytes + NUL, cycled over 72 bytes, big-endian words
      const unsigned char* pw = reinterpret_cast<const unsigned char*>(j.password.c_str());
      size_t plen = j.password.size() + 1, pos = 0;
      for (int i = 0; i < 18; ++i) {
        uint32_t w = 0;
        for (int b = 0; b < 4; ++b) {
          w = (w << 8) | pw[pos];
          pos = (pos + 1) % plen;
        }
        key[l][i] = w;
      }
      for (int i = 0; i < 4; ++i)
        salt[l][i] = (uint32_t(j.salt[4 * i]) << 24) | (uint32_t(j.salt[4 * i + 1]) << 16) |
                     (uint32_t(j.salt[4 * i + 2]) << 8) | j.salt[4 * i + 3];
      for (int i = 0; i < 18; ++i) saltkey[l][i] = salt[l][i % 4];
    }
    expand<true>(key);
    uint64_t rounds = uint64_t(1) << jobs[0]->cost;
    for (uint64_t r = 0; r < rounds; ++r) {
      expand<false>(key);
      expand<false>(saltkey);
    }
    // encrypt "OrpheanBeholderScryDoubt" 64 times
    static const uint32_t magic[6] = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
    uint32_t cdata[N][6];
    for (int l = 0; l < N; ++l) std::memcpy(cdata[l], magic, sizeof magic);
    for (int i = 0; i < 6; i += 2) {
      uint32_t L[N], R[N];
      for (int l = 0; l < N; ++l) { L[l] = cdata[l][i]; R[l] = cdata[l][i + 1]; }
      for (int k = 0; k < 64; ++k) encrypt(L, R);
      for (int l = 0; l < N; ++l) { cdata[l][i] = L[l]; cdata[l][i + 1] = R[l]; }
    }
    for (int l = 0; l < N; ++l) {
      Job& j = *jobs[l];
      uint8_t out[24];
      for (int i = 0; i < 6; ++i) {
        out[4 * i] = uint8_t(cdata[l][i] >> 24);
        out[4 * i + 1] = uint8_t(cdata[l][i] >> 16);
        out[4 * i + 2] = uint8_t(cdata[l][i] >> 8);
        out[4 * i + 3] = uint8_t(cdata[l][i]);
      }
      char head[8] = {'$', '2', j.variant, '$', char('0' + j.cost / 10), char('0' + j.cost % 10), '$', 0};
      j.result = head;
      j.result += j.salt_str;
      b64_encode(j.result, out, 23);  // bcrypt outputs 23 of the 24 bytes
    }
  }
};

// Computes n (1..4) jobs of the same cost together.
void compute(Job* const* jobs, int n);

}  // namespace bcrypt
