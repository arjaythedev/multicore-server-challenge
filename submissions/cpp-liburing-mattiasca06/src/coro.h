// Minimal coroutine types. Everything runs on one worker thread, so no synchronization is needed.
#pragma once
#include <coroutine>
#include <exception>
#include <utility>

// Lazy awaitable task: starts when awaited, resumes its awaiter on completion.
template <class T> struct Task {
    struct promise_type {
        T value{};
        std::exception_ptr ex;
        std::coroutine_handle<> cont;
        Task get_return_object() { return Task{std::coroutine_handle<promise_type>::from_promise(*this)}; }
        std::suspend_always initial_suspend() noexcept { return {}; }
        struct Final {
            bool await_ready() noexcept { return false; }
            std::coroutine_handle<> await_suspend(std::coroutine_handle<promise_type> h) noexcept {
                return h.promise().cont ? h.promise().cont : std::noop_coroutine();
            }
            void await_resume() noexcept {}
        };
        Final final_suspend() noexcept { return {}; }
        void return_value(T v) { value = std::move(v); }
        void unhandled_exception() { ex = std::current_exception(); }
    };

    explicit Task(std::coroutine_handle<promise_type> h) : h_(h) {}
    Task(Task &&o) noexcept : h_(std::exchange(o.h_, {})) {}
    Task(const Task &) = delete;
    ~Task() {
        if (h_) h_.destroy();
    }

    bool await_ready() const noexcept { return false; }
    std::coroutine_handle<> await_suspend(std::coroutine_handle<> c) noexcept {
        h_.promise().cont = c;
        return h_;
    }
    T await_resume() {
        if (h_.promise().ex) std::rethrow_exception(h_.promise().ex);
        return std::move(h_.promise().value);
    }

  private:
    std::coroutine_handle<promise_type> h_;
};

// Fire-and-forget root coroutine; its frame is freed when it finishes.
struct Detached {
    struct promise_type {
        Detached get_return_object() { return {}; }
        std::suspend_never initial_suspend() noexcept { return {}; }
        std::suspend_never final_suspend() noexcept { return {}; }
        void return_void() {}
        void unhandled_exception() { std::terminate(); }
    };
};
