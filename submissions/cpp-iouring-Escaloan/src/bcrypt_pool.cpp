// bcrypt worker pool. Jobs from every loop go into one queue. A worker that holds the assembler role collects up
// to four jobs of equal cost (waiting up to kBcryptBatchWaitMs for the batch to fill), releases the role and
// computes them interleaved; with several workers the next batch is assembled while this one runs, so batches are
// never split between workers. Each completion is posted back to the loop that owns the request.
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <thread>

#include "bcrypt.hpp"
#include "server.hpp"
#include "util.hpp"

namespace {

struct PoolJob {
  int loop_id;
  Request* req;
  bool verify;
  int cost;  // -1: malformed stored hash (fails without work)
  std::string_view password;
};

std::mutex g_mu;
std::condition_variable g_cv;
std::deque<PoolJob> g_jobs;
std::mutex g_assemble;  // held by the worker currently collecting a batch

void complete(const PoolJob& j, bool ok) {
  InboxMsg m{};
  m.kind = InboxMsg::BcryptDone;
  m.ok = ok;
  m.req = j.req;
  post_to_loop(j.loop_id, m);
}

// Takes up to four equal-cost jobs, waiting for the batch to fill. Called with the assembler role held.
int assemble(PoolJob out[4]) {
  std::unique_lock<std::mutex> lk(g_mu);
  g_cv.wait(lk, [] { return !g_jobs.empty(); });
  int n = 0;
  out[n++] = g_jobs.front();
  g_jobs.pop_front();
  if (out[0].cost < 0) return n;
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(cfg::kBcryptBatchWaitMs);
  while (n < 4) {
    for (auto it = g_jobs.begin(); it != g_jobs.end() && n < 4;) {
      if (it->cost == out[0].cost) {
        out[n++] = *it;
        it = g_jobs.erase(it);
      } else {
        ++it;
      }
    }
    if (n == 4 || cfg::kBcryptBatchWaitMs == 0) break;
    if (g_cv.wait_until(lk, deadline) == std::cv_status::timeout) {
      // Last sweep after the window closes.
      for (auto it = g_jobs.begin(); it != g_jobs.end() && n < 4;) {
        if (it->cost == out[0].cost) {
          out[n++] = *it;
          it = g_jobs.erase(it);
        } else {
          ++it;
        }
      }
      break;
    }
  }
  return n;
}

void worker() {
  if (cfg::kBcryptNice) setpriority(PRIO_PROCESS, pid_t(syscall(SYS_gettid)), cfg::kBcryptNice);
  for (;;) {
    PoolJob batch[4];
    int n;
    {
      std::lock_guard<std::mutex> role(g_assemble);
      n = assemble(batch);
    }
    if (batch[0].cost < 0) {
      complete(batch[0], false);
      continue;
    }
    bcrypt::Job jobs[4];
    for (int k = 0; k < n; ++k) {
      Request* r = batch[k].req;
      jobs[k].password = batch[k].password;
      jobs[k].cost = batch[k].cost;
      if (batch[k].verify) {
        jobs[k].stored = std::string_view(r->hash, r->hash_len);
      } else if (getrandom(jobs[k].salt, 16, 0) != 16) {
        jobs[k].cost = -1;
      }
    }
    bcrypt::run(jobs, n);
    for (int k = 0; k < n; ++k) {
      bool ok = jobs[k].ok;
      if (ok && !batch[k].verify) {
        std::memcpy(batch[k].req->hash, jobs[k].out, bcrypt::kHashLen);
        batch[k].req->hash_len = std::uint8_t(bcrypt::kHashLen);
      }
      complete(batch[k], ok);
    }
  }
}

void submit(Loop& L, Request* r, std::string_view pw, bool verify) {
  PoolJob j{L.id, r, verify, cfg::kBcryptCost, pw};
  if (verify) {
    int cost;
    unsigned char salt[16];
    char prefix[4];
    j.cost = bcrypt::parse(std::string_view(r->hash, r->hash_len), cost, salt, prefix) ? cost : -1;
  }
  {
    std::lock_guard<std::mutex> g(g_mu);
    g_jobs.push_back(j);
  }
  g_cv.notify_all();
}

}  // namespace

void bcrypt_pool_start() {
  if (!bcrypt::self_test()) util::die("bcrypt self-test failed");
  for (int i = 0; i < cfg::kBcryptThreads; ++i) std::thread(worker).detach();
}
void bcrypt_submit_verify(Loop& L, Request* r, std::string_view password) { submit(L, r, password, true); }
void bcrypt_submit_hash(Loop& L, Request* r, std::string_view password) { submit(L, r, password, false); }
