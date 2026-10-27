#include "bcrypt.hpp"

#include <crypt.h>
#include <openssl/crypto.h>
#include <sys/random.h>

#include <cstring>

#include "bf_tables.hpp"

namespace bcrypt {
namespace {

constexpr char kAlphabet[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

int alpha_index(char c) {
  if (c == '.') return 0;
  if (c == '/') return 1;
  if (c >= 'A' && c <= 'Z') return c - 'A' + 2;
  if (c >= 'a' && c <= 'z') return c - 'a' + 28;
  if (c >= '0' && c <= '9') return c - '0' + 54;
  return -1;
}

// bcrypt's base64: standard bit order, its own alphabet, no padding.
std::size_t encode(const unsigned char* in, std::size_t n, char* out) {
  std::size_t o = 0, i = 0;
  for (; i + 3 <= n; i += 3) {
    std::uint32_t v = (std::uint32_t(in[i]) << 16) | (std::uint32_t(in[i + 1]) << 8) | in[i + 2];
    out[o++] = kAlphabet[v >> 18];
    out[o++] = kAlphabet[(v >> 12) & 63];
    out[o++] = kAlphabet[(v >> 6) & 63];
    out[o++] = kAlphabet[v & 63];
  }
  if (n - i == 1) {
    std::uint32_t v = std::uint32_t(in[i]) << 16;
    out[o++] = kAlphabet[v >> 18];
    out[o++] = kAlphabet[(v >> 12) & 63];
  } else if (n - i == 2) {
    std::uint32_t v = (std::uint32_t(in[i]) << 16) | (std::uint32_t(in[i + 1]) << 8);
    out[o++] = kAlphabet[v >> 18];
    out[o++] = kAlphabet[(v >> 12) & 63];
    out[o++] = kAlphabet[(v >> 6) & 63];
  }
  return o;
}

// Decodes 22 characters into 16 salt bytes (the last character's low 4 bits are ignored, as in Go and libxcrypt).
bool decode_salt(const char* s, unsigned char out[16]) {
  int v[24] = {};
  for (int i = 0; i < 22; ++i) {
    v[i] = alpha_index(s[i]);
    if (v[i] < 0) return false;
  }
  int o = 0;
  for (int i = 0; i < 24 && o < 16; i += 4) {
    std::uint32_t w = (std::uint32_t(v[i]) << 18) | (std::uint32_t(v[i + 1]) << 12) | (std::uint32_t(v[i + 2]) << 6) |
                      std::uint32_t(v[i + 3]);
    out[o++] = static_cast<unsigned char>(w >> 16);
    if (o < 16) out[o++] = static_cast<unsigned char>(w >> 8);
    if (o < 16) out[o++] = static_cast<unsigned char>(w);
  }
  return true;
}

struct State {
  std::uint32_t S[4][256];
  std::uint32_t P[18];
};

[[gnu::always_inline]] inline std::uint32_t F(const State& s, std::uint32_t x) {
  return ((s.S[0][x >> 24] + s.S[1][(x >> 16) & 0xff]) ^ s.S[2][(x >> 8) & 0xff]) + s.S[3][x & 0xff];
}

// Encrypts one block in each of N lanes; the lanes' dependency chains interleave.
template <int N>
[[gnu::always_inline]] inline void encipher(State* st, std::uint32_t* L, std::uint32_t* R) {
  std::uint32_t l[N], r[N];
#pragma GCC unroll 4
  for (int k = 0; k < N; ++k) {
    l[k] = L[k] ^ st[k].P[0];
    r[k] = R[k];
  }
#pragma GCC unroll 8
  for (int i = 1; i <= 16; i += 2) {
#pragma GCC unroll 4
    for (int k = 0; k < N; ++k) r[k] ^= F(st[k], l[k]) ^ st[k].P[i];
#pragma GCC unroll 4
    for (int k = 0; k < N; ++k) l[k] ^= F(st[k], r[k]) ^ st[k].P[i + 1];
  }
#pragma GCC unroll 4
  for (int k = 0; k < N; ++k) {
    L[k] = r[k] ^ st[k].P[17];
    R[k] = l[k];
  }
}

// P ^= key words, then re-derive P and S by chained encryption. With `data`, each step first XORs in the next
// two words of the cyclic 16-byte salt stream (the initial "expandstate"); without, it is "expand0state".
template <int N, bool kWithData>
[[gnu::noinline]] void expand(State* st, const std::uint32_t (*keyw)[18], const std::uint32_t (*saltw)[4]) {
#pragma GCC unroll 4
  for (int k = 0; k < N; ++k)
    for (int i = 0; i < 18; ++i) st[k].P[i] ^= keyw[k][i];
  std::uint32_t l[N] = {}, r[N] = {};
  int d = 0;  // salt stream position (words), period 4
  for (int i = 0; i < 18; i += 2) {
    if constexpr (kWithData) {
      for (int k = 0; k < N; ++k) {
        l[k] ^= saltw[k][d & 3];
        r[k] ^= saltw[k][(d + 1) & 3];
      }
      d += 2;
    }
    encipher<N>(st, l, r);
    for (int k = 0; k < N; ++k) {
      st[k].P[i] = l[k];
      st[k].P[i + 1] = r[k];
    }
  }
  for (int b = 0; b < 4; ++b) {
    for (int i = 0; i < 256; i += 2) {
      if constexpr (kWithData) {
        for (int k = 0; k < N; ++k) {
          l[k] ^= saltw[k][d & 3];
          r[k] ^= saltw[k][(d + 1) & 3];
        }
        d += 2;
      }
      encipher<N>(st, l, r);
      for (int k = 0; k < N; ++k) {
        st[k].S[b][i] = l[k];
        st[k].S[b][i + 1] = r[k];
      }
    }
  }
}

std::uint32_t be32(const unsigned char* p) {
  return (std::uint32_t(p[0]) << 24) | (std::uint32_t(p[1]) << 16) | (std::uint32_t(p[2]) << 8) | p[3];
}

// The first 72 bytes of the cyclic key stream (password truncated to 72 bytes, plus NUL) as 18 words.
void key_words(std::string_view pw, std::uint32_t out[18]) {
  unsigned char key[73];
  std::size_t n = pw.size() > 72 ? 72 : pw.size();
  std::memcpy(key, pw.data(), n);
  key[n] = 0;
  std::size_t klen = n + 1, j = 0;
  unsigned char stream[72];
  for (int i = 0; i < 72; ++i) {
    stream[i] = key[j];
    j = j + 1 == klen ? 0 : j + 1;
  }
  for (int i = 0; i < 18; ++i) out[i] = be32(stream + 4 * i);
  OPENSSL_cleanse(key, sizeof key);
  OPENSSL_cleanse(stream, sizeof stream);
}

template <int N>
void run_n(Job* jobs) {
  alignas(64) State st[N];
  std::uint32_t keyw[N][18], saltw[N][4], saltw18[N][18];
  for (int k = 0; k < N; ++k) {
    std::memcpy(st[k].P, bf::kInitP, sizeof st[k].P);
    std::memcpy(st[k].S, bf::kInitS, sizeof st[k].S);
    key_words(jobs[k].password, keyw[k]);
    for (int i = 0; i < 4; ++i) saltw[k][i] = be32(jobs[k].salt + 4 * i);
    for (int i = 0; i < 18; ++i) saltw18[k][i] = saltw[k][i & 3];
  }
  expand<N, true>(st, keyw, saltw);
  std::uint64_t rounds = std::uint64_t(1) << jobs[0].cost;
  for (std::uint64_t i = 0; i < rounds; ++i) {
    expand<N, false>(st, keyw, nullptr);
    expand<N, false>(st, saltw18, nullptr);
  }
  static const unsigned char kMagic[24] = {'O', 'r', 'p', 'h', 'e', 'a', 'n', 'B', 'e', 'h', 'o', 'l',
                                           'd', 'e', 'r', 'S', 'c', 'r', 'y', 'D', 'o', 'u', 'b', 't'};
  std::uint32_t c[3][2][N];
  for (int b = 0; b < 3; ++b)
    for (int k = 0; k < N; ++k) {
      c[b][0][k] = be32(kMagic + 8 * b);
      c[b][1][k] = be32(kMagic + 8 * b + 4);
    }
  for (int i = 0; i < 64; ++i)
    for (int b = 0; b < 3; ++b) encipher<N>(st, c[b][0], c[b][1]);

  for (int k = 0; k < N; ++k) {
    Job& j = jobs[k];
    unsigned char raw[24];
    for (int b = 0; b < 3; ++b) {
      for (int h = 0; h < 2; ++h) {
        std::uint32_t w = c[b][h][k];
        raw[8 * b + 4 * h] = static_cast<unsigned char>(w >> 24);
        raw[8 * b + 4 * h + 1] = static_cast<unsigned char>(w >> 16);
        raw[8 * b + 4 * h + 2] = static_cast<unsigned char>(w >> 8);
        raw[8 * b + 4 * h + 3] = static_cast<unsigned char>(w);
      }
    }
    char hash31[32];
    encode(raw, 23, hash31);
    if (!j.stored.empty()) {
      // Compare the 31-character digest part; prefix, cost and salt come from the stored string itself.
      j.ok = CRYPTO_memcmp(hash31, j.stored.data() + 29, 31) == 0;
      std::memcpy(j.out, j.stored.data(), 29);
      std::memcpy(j.out + 29, hash31, 31);
    } else {
      std::memcpy(j.out, "$2b$", 4);
      j.out[4] = char('0' + j.cost / 10);
      j.out[5] = char('0' + j.cost % 10);
      j.out[6] = '$';
      encode(j.salt, 16, j.out + 7);
      std::memcpy(j.out + 29, hash31, 31);
      j.ok = true;
    }
    j.out[60] = 0;
  }
  for (int k = 0; k < N; ++k) OPENSSL_cleanse(keyw[k], sizeof keyw[k]);
  OPENSSL_cleanse(st, sizeof st);
}

}  // namespace

bool parse(std::string_view s, int& cost, unsigned char salt[16], char prefix[4]) {
  if (s.size() != kHashLen || s[0] != '$' || s[1] != '2' || s[3] != '$' || s[6] != '$') return false;
  if (s[2] != 'a' && s[2] != 'b' && s[2] != 'y') return false;
  if (s[4] < '0' || s[4] > '9' || s[5] < '0' || s[5] > '9') return false;
  cost = (s[4] - '0') * 10 + (s[5] - '0');
  if (cost < 4 || cost > 31) return false;
  for (std::size_t i = 29; i < 60; ++i)
    if (alpha_index(s[i]) < 0) return false;
  std::memcpy(prefix, s.data(), 4);
  return decode_salt(s.data() + 7, salt);
}

void run(Job* jobs, int n) {
  for (int k = 0; k < n; ++k) {
    jobs[k].ok = false;
    if (!jobs[k].stored.empty()) {
      char prefix[4];
      if (!parse(jobs[k].stored, jobs[k].cost, jobs[k].salt, prefix)) {
        // Malformed stored hash: run nothing for it; verification fails.
        jobs[k].cost = -1;
      }
    }
  }
  // Compact out malformed entries, then run in one batch (callers group equal costs).
  Job* valid[4];
  int m = 0;
  for (int k = 0; k < n; ++k)
    if (jobs[k].cost >= 4) valid[m++] = &jobs[k];
  if (m == 0) return;
  bool same = true;
  for (int k = 1; k < m; ++k) same &= valid[k]->cost == valid[0]->cost;
  if (!same) {  // defensive: run individually
    for (int k = 0; k < m; ++k) run_n<1>(valid[k]);
    return;
  }
  Job tmp[4];
  for (int k = 0; k < m; ++k) tmp[k] = *valid[k];
  switch (m) {
    case 1: run_n<1>(tmp); break;
    case 2: run_n<2>(tmp); break;
    case 3: run_n<3>(tmp); break;
    default: run_n<4>(tmp); break;
  }
  for (int k = 0; k < m; ++k) {
    std::memcpy(valid[k]->out, tmp[k].out, sizeof tmp[k].out);
    valid[k]->ok = tmp[k].ok;
  }
  OPENSSL_cleanse(tmp, sizeof tmp);
}

bool self_test() {
  // Compares against libxcrypt at cost 4 on a few fixed and random inputs (fast: about a millisecond each).
  const char* pws[4] = {"", "password123", "U*U*U*U*", "a-long-password-that-is-longer-than-seventy-two-bytes-in-total-0123456789"};
  Job jobs[4];
  for (int k = 0; k < 4; ++k) {
    jobs[k].password = pws[k];
    jobs[k].cost = 4;
    if (getrandom(jobs[k].salt, 16, 0) != 16) return false;
  }
  run(jobs, 4);
  for (int k = 0; k < 4; ++k) {
    crypt_data cd{};
    char* ref = crypt_rn(pws[k], jobs[k].out, &cd, sizeof cd);
    if (!ref || std::strcmp(ref, jobs[k].out) != 0) return false;
    // And verification of our own output.
    Job v;
    v.password = pws[k];
    v.stored = std::string_view(jobs[k].out, 60);
    run(&v, 1);
    if (!v.ok) return false;
  }
  return true;
}

}  // namespace bcrypt
