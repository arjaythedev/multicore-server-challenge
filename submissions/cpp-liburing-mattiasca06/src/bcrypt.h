// bcrypt (cost 10) on a small pool of low-priority threads. Results are handed back to the owning worker.
#pragma once
#include <coroutine>
#include <string>

struct Worker;

struct BcryptResult {
    bool ok = false;      // verify: password matches; hash: hashing succeeded
    std::string hash;     // hash: the new "$2b$10$..." string
};

// co_await'ed from a request coroutine; resumed on the worker's own thread.
struct BcryptAwait {
    BcryptAwait(Worker &w, bool hash, std::string password, std::string stored = {})
        : w(w), hash(hash), password(std::move(password)), stored(std::move(stored)) {}
    bool await_ready() const noexcept { return false; }
    void await_suspend(std::coroutine_handle<> c);
    BcryptResult await_resume() { return std::move(result); }

    Worker &w;
    bool hash;
    std::string password, stored;
    BcryptResult result;
    std::coroutine_handle<> h;
};

namespace bcrypt_pool {
void start(int threads);
}
