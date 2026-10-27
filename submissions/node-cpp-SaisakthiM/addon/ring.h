// Ring buffers used by the addon.
//
//  * SpscRing<T, N>  lock-free single-producer / single-consumer ring (fixed power-of-two capacity).
//                    One pair per bcrypt thread: the event loop is the only producer of `in` and the only
//                    consumer of `out`; the bcrypt thread is the other end of both. No locks, no allocation.
//  * FifoRing<T>     growable single-threaded ring. Holds the requests in flight on one pipelined Postgres
//                    connection: results come back in the order the queries were sent, so the head of the ring
//                    is always the request the next result belongs to.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

template <typename T, size_t N>
class SpscRing {
  static_assert(N >= 2 && (N & (N - 1)) == 0, "N must be a power of two");

 public:
  bool push(T v) {
    const size_t t = tail_.load(std::memory_order_relaxed);
    if (t - head_.load(std::memory_order_acquire) == N) return false;  // full
    buf_[t & (N - 1)] = std::move(v);
    tail_.store(t + 1, std::memory_order_release);
    return true;
  }

  bool pop(T& out) {
    const size_t h = head_.load(std::memory_order_relaxed);
    if (h == tail_.load(std::memory_order_acquire)) return false;  // empty
    out = std::move(buf_[h & (N - 1)]);
    head_.store(h + 1, std::memory_order_release);
    return true;
  }

 private:
  alignas(64) std::atomic<size_t> head_{0};  // consumer index
  alignas(64) std::atomic<size_t> tail_{0};  // producer index
  alignas(64) T buf_[N];
};

template <typename T>
class FifoRing {
 public:
  FifoRing() : buf_(16), mask_(15) {}

  bool empty() const { return head_ == tail_; }
  size_t size() const { return tail_ - head_; }

  void push(T v) {
    if (size() == buf_.size()) grow();
    buf_[tail_ & mask_] = std::move(v);
    ++tail_;
  }

  T& front() { return buf_[head_ & mask_]; }

  void pop() {
    buf_[head_ & mask_] = T();
    ++head_;
  }

 private:
  void grow() {
    const size_t n = size();
    std::vector<T> nb(buf_.size() * 2);
    for (size_t i = 0; i < n; ++i) nb[i] = std::move(buf_[(head_ + i) & mask_]);
    buf_.swap(nb);
    mask_ = buf_.size() - 1;
    head_ = 0;
    tail_ = n;
  }

  std::vector<T> buf_;
  size_t mask_;
  size_t head_ = 0;
  size_t tail_ = 0;
};
