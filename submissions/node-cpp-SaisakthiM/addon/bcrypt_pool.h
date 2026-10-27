// bcrypt (cost 10) on dedicated native threads, so a ~60 ms hash never blocks the Node event loop.
//
// Hand-off is two lock-free SPSC rings per thread (see ring.h):
//   event loop --in ring--> bcrypt thread --out ring--> event loop
// The thread sleeps on a semaphore while idle; it wakes the loop with uv_async_send after pushing a result.
#pragma once

#include <openssl/crypto.h>
#include <sys/random.h>
#include <uv.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <semaphore>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include "vendor/crypt_blowfish.h"
}
#include "ring.h"

struct BcryptJob {
  uint32_t id = 0;
  bool verify = false;
  std::string password;
  std::string hash;  // verify: the stored hash (input). hash: the produced hash (output).
  bool ok = false;
};

class BcryptPool {
 public:
  using Callback = void (*)(void* ctx, BcryptJob* job);  // runs on the event-loop thread

  BcryptPool(uv_loop_t* loop, int threads, Callback cb, void* ctx) : cb_(cb), ctx_(ctx) {
    uv_async_init(loop, &async_, &BcryptPool::on_async);
    async_.data = this;
    uv_unref(reinterpret_cast<uv_handle_t*>(&async_));
    if (threads < 1) threads = 1;
    for (int i = 0; i < threads; ++i) workers_.push_back(std::make_unique<Worker>());
    for (auto& w : workers_) {
      Worker* wp = w.get();
      std::thread([this, wp] { run(wp); }).detach();
    }
  }

  // Event-loop thread only. Takes ownership of `job` on success; returns false when every queue is full.
  bool submit(BcryptJob* job) {
    const size_t n = workers_.size();
    for (size_t k = 0; k < n; ++k) {
      Worker* w = workers_[(next_ + k) % n].get();
      if (w->in.push(job)) {
        next_ = (next_ + k + 1) % n;
        w->sem.release();
        return true;
      }
    }
    return false;
  }

 private:
  struct Worker {
    SpscRing<BcryptJob*, 1024> in;
    SpscRing<BcryptJob*, 1024> out;
    std::counting_semaphore<> sem{0};
  };

  static void on_async(uv_async_t* h) { static_cast<BcryptPool*>(h->data)->drain(); }

  void drain() {
    for (auto& w : workers_) {
      BcryptJob* j = nullptr;
      while (w->out.pop(j)) {
        cb_(ctx_, j);
        delete j;
      }
    }
  }

  void run(Worker* w) {
    for (;;) {
      w->sem.acquire();
      BcryptJob* job = nullptr;
      while (!w->in.pop(job)) std::this_thread::yield();  // pushed before release(): practically never loops
      process(job);
      while (!w->out.push(job)) {
        uv_async_send(&async_);
        std::this_thread::yield();
      }
      uv_async_send(&async_);
    }
  }

  static void process(BcryptJob* j) {
    char out[64];
    if (j->verify) {
      const char* r = _crypt_blowfish_rn(j->password.c_str(), j->hash.c_str(), out, int(sizeof out));
      j->ok = r != nullptr && std::strlen(out) == j->hash.size() &&
              CRYPTO_memcmp(out, j->hash.data(), j->hash.size()) == 0;
      return;
    }
    unsigned char salt[16];
    if (getrandom(salt, sizeof salt, 0) != ssize_t(sizeof salt)) {
      j->ok = false;
      return;
    }
    char setting[64];
    if (_crypt_gensalt_blowfish_rn("$2b$", 10, reinterpret_cast<const char*>(salt), int(sizeof salt), setting,
                                   int(sizeof setting)) == nullptr) {
      j->ok = false;
      return;
    }
    const char* r = _crypt_blowfish_rn(j->password.c_str(), setting, out, int(sizeof out));
    if (r == nullptr) {
      j->ok = false;
      return;
    }
    j->hash.assign(out);
    j->ok = true;
  }

  uv_async_t async_;
  std::vector<std::unique_ptr<Worker>> workers_;
  size_t next_ = 0;
  Callback cb_;
  void* ctx_;
};
