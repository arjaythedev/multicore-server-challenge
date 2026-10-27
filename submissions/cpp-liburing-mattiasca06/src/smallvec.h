// Vector with N elements of inline storage; spills to the heap beyond that. Keeps the common short lists off malloc.
#pragma once
#include <cstddef>
#include <initializer_list>
#include <new>
#include <type_traits>
#include <utility>

template <class T, size_t N> class SmallVec {
public:
    SmallVec() = default;
    SmallVec(std::initializer_list<T> il) {
        reserve(il.size());
        for (const T &x : il) push_back(x);
    }
    SmallVec(const SmallVec &o) {
        reserve(o.n_);
        for (const T &x : o) push_back(x);
    }
    SmallVec(SmallVec &&o) noexcept(std::is_nothrow_move_constructible_v<T>) {
        if (o.p_ != o.inl()) {  // steal the heap block
            p_ = o.p_;
            cap_ = o.cap_;
            n_ = o.n_;
            o.p_ = o.inl();
            o.cap_ = N;
            o.n_ = 0;
        } else {
            for (size_t i = 0; i < o.n_; i++) new (p_ + i) T(std::move(o.p_[i]));
            n_ = o.n_;
            o.clear();
        }
    }
    SmallVec &operator=(SmallVec &&o) noexcept {
        if (this != &o) {
            this->~SmallVec();
            new (this) SmallVec(std::move(o));
        }
        return *this;
    }
    SmallVec &operator=(const SmallVec &o) {
        if (this != &o) {
            SmallVec t(o);
            *this = std::move(t);
        }
        return *this;
    }
    ~SmallVec() {
        clear();
        if (p_ != inl()) ::operator delete(p_);
    }
    void reserve(size_t c) {
        if (c <= cap_) return;
        T *np = static_cast<T *>(::operator new(c * sizeof(T)));
        for (size_t i = 0; i < n_; i++) {
            new (np + i) T(std::move(p_[i]));
            p_[i].~T();
        }
        if (p_ != inl()) ::operator delete(p_);
        p_ = np;
        cap_ = c;
    }
    void push_back(const T &x) {
        if (n_ == cap_) {
            T tmp(x);  // x may live inside this vector
            reserve(cap_ * 2);
            new (p_ + n_++) T(std::move(tmp));
        } else {
            new (p_ + n_++) T(x);
        }
    }
    void push_back(T &&x) {
        if (n_ == cap_) {
            T tmp(std::move(x));
            reserve(cap_ * 2);
            new (p_ + n_++) T(std::move(tmp));
        } else {
            new (p_ + n_++) T(std::move(x));
        }
    }
    void clear() {
        for (size_t i = 0; i < n_; i++) p_[i].~T();
        n_ = 0;
    }
    size_t size() const { return n_; }
    bool empty() const { return n_ == 0; }
    T &operator[](size_t i) { return p_[i]; }
    const T &operator[](size_t i) const { return p_[i]; }
    T *begin() { return p_; }
    T *end() { return p_ + n_; }
    const T *begin() const { return p_; }
    const T *end() const { return p_ + n_; }
    T &back() { return p_[n_ - 1]; }

private:
    T *inl() { return reinterpret_cast<T *>(buf_); }
    const T *inl() const { return reinterpret_cast<const T *>(buf_); }
    alignas(T) unsigned char buf_[N * sizeof(T)];
    T *p_ = inl();
    size_t n_ = 0, cap_ = N;
};
