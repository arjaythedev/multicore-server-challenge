// Minimal coroutine types. Everything runs on one worker thread, so no synchronization is needed.
#pragma once
#include <coroutine>
#include <cstddef>
#include <new>
#include <exception>
#include <utility>
// Coroutine frames come from per-thread free lists (64-byte size classes up to 8 KiB) instead of malloc: a request
// allocates and frees several frames, and they are all the same few sizes.
namespace frame_pool {
inline constexpr size_t kClass = 64, kClasses = 128;  // 64 .. 8192 bytes
struct Node { Node *next; };
inline Node *&head(size_t c) {
    thread_local Node *heads[kClasses] = {};
    return heads[c];
}
inline void *alloc(size_t n) {
    size_t c = (n + kClass - 1) / kClass;
    if (c == 0 || c > kClasses) return ::operator new(n);
    Node *&h = head(c - 1);
    if (h) {
        Node *r = h;
        h = r->next;
        if (h) __builtin_prefetch(h, 1);  // the next frame's first line is touched by the following alloc
        return r;
    }
    return ::operator new(c * kClass);
}
inline void release(void *p, size_t n) {
    size_t c = (n + kClass - 1) / kClass;
    if (c == 0 || c > kClasses) return ::operator delete(p);
    Node *&h = head(c - 1);
    Node *nd = static_cast<Node *>(p);
    nd->next = h;
    h = nd;
}
}  // namespace frame_pool


// Lazy awaitable task: starts when awaited, resumes its awaiter on completion.
template <class T> struct Task {
    struct promise_type {
        static void *operator new(size_t n) { return frame_pool::alloc(n); }
        static void operator delete(void *p, size_t n) { frame_pool::release(p, n); }
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
        static void *operator new(size_t n) { return frame_pool::alloc(n); }
        static void operator delete(void *p, size_t n) { frame_pool::release(p, n); }
        Detached get_return_object() { return {}; }
        std::suspend_never initial_suspend() noexcept { return {}; }
        std::suspend_never final_suspend() noexcept { return {}; }
        void return_void() {}
        void unhandled_exception() { std::terminate(); }
    };
};
