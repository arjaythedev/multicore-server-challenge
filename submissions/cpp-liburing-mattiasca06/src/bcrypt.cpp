#include "bcrypt.h"

#include <crypt.h>
#include <openssl/crypto.h>
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>

#include "worker.h"

namespace {

std::mutex g_mu;
std::condition_variable g_cv;
std::deque<BcryptAwait *> g_jobs;

void compute(BcryptAwait &j, crypt_data &cd) {
    if (j.hash) {
        unsigned char rnd[16];
        char salt[64];
        if (getrandom(rnd, sizeof rnd, 0) != ssize_t(sizeof rnd)) return;
        if (!crypt_gensalt_rn("$2b$", 10, reinterpret_cast<char *>(rnd), sizeof rnd, salt, sizeof salt)) return;
        const char *h = crypt_r(j.password.c_str(), salt, &cd);
        if (!h || h[0] == '*') return;
        j.result.hash = h;
        j.result.ok = true;
    } else {
        const char *h = crypt_r(j.password.c_str(), j.stored.c_str(), &cd);
        j.result.ok = h && h[0] != '*' && strlen(h) == j.stored.size() &&
                      CRYPTO_memcmp(h, j.stored.data(), j.stored.size()) == 0;
    }
}

void loop() {
    // Hashing is rare next to the rest of the traffic: let Postgres and the event loops win the CPU.
    setpriority(PRIO_PROCESS, pid_t(syscall(SYS_gettid)), 10);
    auto cd = std::make_unique<crypt_data>();
    for (;;) {
        BcryptAwait *j;
        {
            std::unique_lock lk(g_mu);
            g_cv.wait(lk, [] { return !g_jobs.empty(); });
            j = g_jobs.front();
            g_jobs.pop_front();
        }
        memset(cd.get(), 0, sizeof *cd);
        compute(*j, *cd);
        j->w.post_done(j);
    }
}

}  // namespace

void BcryptAwait::await_suspend(std::coroutine_handle<> c) {
    h = c;
    {
        std::lock_guard lk(g_mu);
        g_jobs.push_back(this);
    }
    g_cv.notify_one();
}

void bcrypt_pool::start(int threads) {
    for (int i = 0; i < threads; i++) std::thread(loop).detach();
}
