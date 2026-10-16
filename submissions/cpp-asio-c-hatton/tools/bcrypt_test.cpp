// Checks the interleaved bcrypt against libxcrypt and times it. Not part of the server build.
#include <crypt.h>
#include <chrono>
#include <cstdio>
#include <random>
#include "../src/bcrypt.hpp"
int main() {
  std::mt19937 rng(42);
  int bad = 0, total = 0;
  for (int cost : {4, 5, 10}) {
    for (int iter = 0; iter < (cost == 10 ? 8 : 200); iter += 4) {
      bcrypt::Job jobs[4];
      bcrypt::Job* jp[4];
      std::string want[4];
      for (int l = 0; l < 4; ++l) {
        std::string pw;
        int len = int(rng() % 73);
        for (int i = 0; i < len; ++i) pw.push_back(char(1 + rng() % 127));
        const char* pre = (l % 3 == 0) ? "$2a$" : (l % 3 == 1) ? "$2b$" : "$2y$";
        char salt[64];
        crypt_gensalt_rn(pre, cost, nullptr, 0, salt, sizeof salt);
        struct crypt_data d; d.initialized = 0;
        want[l] = crypt_rn(pw.c_str(), salt, &d, sizeof d);
        if (!bcrypt::prepare(jobs[l], pw, salt)) { std::printf("prepare failed\n"); return 1; }
        jp[l] = &jobs[l];
      }
      int n = 1 + iter / 4 % 4;
      bcrypt::compute(jp, n);
      for (int l = 0; l < n; ++l) {
        ++total;
        if (jobs[l].result != want[l]) { ++bad; std::printf("MISMATCH\n %s\n %s\n", jobs[l].result.c_str(), want[l].c_str()); }
      }
    }
  }
  // the seed's hash
  bcrypt::Job j; bcrypt::Job* jp1[1] = {&j};
  bcrypt::prepare(j, "password123", "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq");
  bcrypt::compute(jp1, 1);
  std::printf("seed hash %s\n", j.result == "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq" ? "ok" : "MISMATCH");
  std::printf("%d/%d match\n", total - bad, total);
  // timing at cost 10
  for (int n = 1; n <= 4; ++n) {
    bcrypt::Job js[4]; bcrypt::Job* p[4];
    for (int l = 0; l < 4; ++l) { bcrypt::prepare(js[l], "password123", "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"); p[l] = &js[l]; }
    auto t = std::chrono::steady_clock::now();
    for (int r = 0; r < 4; ++r) bcrypt::compute(p, n);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count() / 4;
    std::printf("N=%d: %.1f ms per batch, %.1f ms per hash\n", n, ms, ms / n);
  }
  auto t = std::chrono::steady_clock::now();
  for (int r = 0; r < 4; ++r) { struct crypt_data d; d.initialized = 0; crypt_rn("password123", "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq", &d, sizeof d); }
  std::printf("libxcrypt: %.1f ms per hash\n", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count() / 4);
  return bad != 0;
}
