#pragma once
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <functional>
#include <chrono>
#include <vector>
#include <algorithm>
#include <coroutine>
#include "bcrypt.hpp"
#include "Common.hpp"

namespace multicore {

inline bool constantTimeEq(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    unsigned char diff = 0;
    for (size_t i = 0; i < a.size(); ++i) diff |= (unsigned char)(a[i] ^ b[i]);
    return diff == 0;
}

class BcryptPool {
public:
    static BcryptPool& instance() {
        static BcryptPool pool;
        return pool;
    }

    using HashCb = std::function<void(std::string)>;
    using VerifyCb = std::function<void(bool)>;

    void hashAsync(std::string pw, HashCb cb) {
        auto setting = common::BcryptGensalt();
        push(std::move(pw), std::move(setting), std::move(cb));
    }

    void verifyAsync(std::string pw, std::string stored, VerifyCb cb) {
        auto want = stored;
        push(std::move(pw), std::move(stored),
             [want = std::move(want), cb = std::move(cb)](const std::string& got) {
                 cb(!got.empty() && constantTimeEq(got, want));
             });
    }

private:
    using Clock = std::chrono::steady_clock;
    struct Task {
        std::string pw, setting;
        int cost;
        Clock::time_point t;
        HashCb cb;
    };

    BcryptPool() {
        for (int i = 0; i < 2; ++i) std::thread(&BcryptPool::worker, this).detach();
    }

    static int costOf(const std::string& s) {
        if (s.size() < 7 || s[0] != '$' || s[3] != '$' || s[6] != '$' ||
            s[4] < '0' || s[4] > '9' || s[5] < '0' || s[5] > '9') return -1;
        return (s[4] - '0') * 10 + (s[5] - '0');
    }

    void push(std::string pw, std::string setting, HashCb cb) {
        const int cost = costOf(setting);
        if (cost < 4 || cost > 31 || pw.size() > 72)
        { cb(""); return; }
        {
            std::lock_guard lk(mu_);
            q_.push_back(Task{std::move(pw), std::move(setting), cost, Clock::now(), std::move(cb)});
        }
        cv_.notify_one();
    }

    [[noreturn]] void worker() {
        std::vector<Task> set;
        std::vector<bcrypt::Job> jobs;
        std::vector<bcrypt::Job*> jobPtrs;

        for (;;) {
            set.clear(); jobs.clear(); jobPtrs.clear();

            {
                std::unique_lock lk(mu_);
                for (;;) {
                    if (q_.empty()) { cv_.wait(lk); continue; }

                    auto odd = q_.end();
                    for (auto it = q_.begin(); it != q_.end(); ++it)
                        if (it->cost != 10) { odd = it; break; }

                    if (odd != q_.end()) {
                        set.push_back(std::move(*odd));
                        q_.erase(odd);
                        break;
                    }

                    auto due = q_.front().t + std::chrono::milliseconds(200);
                    if (q_.size() >= 4 /* lanes */ || Clock::now() >= due) {
                        while (!q_.empty() && set.size() < 4) {
                            set.push_back(std::move(q_.front()));
                            q_.pop_front();
                        }
                        break;
                    }
                    cv_.wait_until(lk, due);
                }
                if (!q_.empty()) cv_.notify_one();
            }
            LOG_DEBUG << "bcrypt batch size=" << set.size();
            jobs.resize(set.size());
            jobPtrs.resize(set.size());
            for (size_t i = 0; i < set.size(); ++i) {
                if (!bcrypt::prepare(jobs[i], set[i].pw, set[i].setting)) {
                    set[i].cb("");
                    continue;
                }
                jobPtrs[i] = &jobs[i];
            }

            bcrypt::compute(jobPtrs.data(), static_cast<int>(jobPtrs.size()));

            for (size_t i = 0; i < set.size(); ++i)
                set[i].cb(jobs[i].result);
        }
    }

    std::mutex mu_;
    std::condition_variable cv_;
    std::deque<Task> q_;
};

    template <typename T>
    struct FutureAwaiter {
        std::shared_future<T> fut;

        bool await_ready() const noexcept {
            return fut.wait_for(std::chrono::seconds(0)) == std::future_status::ready;
        }

        void await_suspend(std::coroutine_handle<> h) {
            std::thread([f = fut, h]() mutable {
                f.wait();
                h.resume();
            }).detach();
        }

        T await_resume() { return fut.get(); }
    };
} // namespace multicore