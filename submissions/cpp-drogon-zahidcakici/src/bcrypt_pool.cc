// bcrypt threads. Hashes are gathered into sets of up to `lanes` (calibrated at startup) that run interleaved: a set
// runs when it is full or BCRYPT_WAIT_MS after its oldest hash arrived. A hash of another cost than 10 runs alone.
#include <openssl/crypto.h>
#include <openssl/rand.h>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <thread>

#include "../native/bcrypt.h"
#include "common.h"

namespace {
using Clock = std::chrono::steady_clock;
struct Task {
  std::string pw, setting;
  int cost;
  Clock::time_point t;
  std::function<void(std::string)> cb;  // the 60-character hash, or empty on failure
};
std::mutex m;
std::condition_variable cv;
std::deque<Task> q;
unsigned lanes = 4;

int costOf(const std::string &s) {
  if (s.size() < 7 || s[0] != '$' || s[3] != '$' || s[6] != '$' || s[4] < '0' || s[4] > '9' || s[5] < '0' || s[5] > '9') return -1;
  return (s[4] - '0') * 10 + (s[5] - '0');
}

void worker() {
  std::vector<Task> set;
  for (;;) {
    {
      std::unique_lock<std::mutex> lk(m);
      for (;;) {
        if (q.empty()) { cv.wait(lk); continue; }
        auto odd = q.end();
        for (auto it = q.begin(); it != q.end(); ++it) if (it->cost != 10) { odd = it; break; }
        if (odd != q.end()) { set.push_back(std::move(*odd)); q.erase(odd); break; }
        auto due = q.front().t + std::chrono::milliseconds(cfg.bcryptWaitMs);
        if (q.size() >= lanes || Clock::now() >= due) {
          while (!q.empty() && set.size() < lanes) { set.push_back(std::move(q.front())); q.pop_front(); }
          break;
        }
        cv.wait_until(lk, due);
      }
      if (!q.empty()) cv.notify_one();
    }
    const char *keys[BC_MAX_LANES], *settings[BC_MAX_LANES];
    unsigned char out[BC_MAX_LANES][61];
    unsigned n = (unsigned)set.size();
    for (unsigned i = 0; i < n; i++) { keys[i] = set[i].pw.c_str(); settings[i] = set[i].setting.c_str(); }
    int ok = bc_hash(keys, settings, out, n);
    for (unsigned i = 0; i < n; i++) {
      Job::wipe(set[i].pw);
      set[i].cb(ok ? std::string((const char *)out[i], 60) : std::string());
    }
    OPENSSL_cleanse(out, sizeof out);
    set.clear();
  }
}

const char BF64[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

// "$2b$10$" + 22 characters of bcrypt's base64 of 16 random bytes
std::string newSetting() {
  unsigned char r[16];
  if (RAND_bytes(r, 16) != 1) return std::string();
  std::string s = "$2b$10$";
  int i = 0;
  for (;;) {
    int c1 = r[i++];
    s += BF64[c1 >> 2];
    c1 = (c1 & 3) << 4;
    if (i >= 16) { s += BF64[c1]; break; }
    int c2 = r[i++];
    c1 |= c2 >> 4; s += BF64[c1];
    c1 = (c2 & 15) << 2;
    c2 = r[i++];
    c1 |= c2 >> 6; s += BF64[c1];
    s += BF64[c2 & 63];
  }
  return s;
}

void push(std::string pw, std::string setting, std::function<void(std::string)> cb) {
  int cost = costOf(setting);
  if (cost < 4 || cost > 31 || pw.size() > 72 || pw.find('\0') != std::string::npos) { cb(std::string()); return; }
  {
    std::lock_guard<std::mutex> lk(m);
    q.push_back(Task{std::move(pw), std::move(setting), cost, Clock::now(), std::move(cb)});
  }
  cv.notify_one();
}
}  // namespace

void bcryptStart() {
  if (!bc_selftest()) { fprintf(stderr, "bcrypt self-test failed\n"); exit(1); }
  if (cfg.bcryptLanes > 0) lanes = (unsigned)std::min(cfg.bcryptLanes, BC_MAX_LANES);
  else {
    // the fastest lane count depends on the CPU (registers, load latency): time each on a cheap cost
    unsigned best = 1;
    double bestNs = 1e18;
    for (unsigned n = 1; n <= BC_MAX_LANES; n++) {
      bc_calibrate(n);
      double ns = std::min(bc_calibrate(n), bc_calibrate(n));
      if (ns < bestNs * 0.97) { best = n; bestNs = ns; }
    }
    lanes = best;
    fprintf(stderr, "bcrypt: %u lanes (%.1f ms per cost-10 hash)\n", lanes, bestNs / 1e6 * 16);
  }
  for (int i = 0; i < cfg.bcryptThreads; i++) std::thread(worker).detach();
}

void bcryptHash(std::string pw, std::function<void(std::string)> cb) {
  std::string s = newSetting();
  if (s.empty()) { cb(std::string()); return; }
  push(std::move(pw), std::move(s), std::move(cb));
}

void bcryptVerify(std::string pw, std::string stored, std::function<void(bool)> cb) {
  std::string want = stored;
  push(std::move(pw), std::move(stored), [want = std::move(want), cb = std::move(cb)](std::string got) {
    bool ok = got.size() == 60 && want.size() == 60 && CRYPTO_memcmp(got.data(), want.data(), 60) == 0;
    cb(ok);
  });
}
