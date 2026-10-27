// Spare string buffers per thread. An idle connection keeps nothing (80k keep-alive connections would otherwise pin
// their largest response each); a busy request picks a warm buffer up again without going through malloc.
#pragma once
#include <string>
#include <utility>
#include <vector>

inline std::vector<std::string> &spare_bufs() {
    thread_local std::vector<std::string> v;
    return v;
}
// Hands an empty buffer's storage to the pool (or back to the allocator when it is big or the pool is full).
inline void release_big(std::string &s) {
    if (!s.empty() || s.capacity() <= 15) return;
    auto &sp = spare_bufs();
    if (s.capacity() <= 32768 && sp.size() < 1024) {
        sp.push_back(std::move(s));
        s = std::string();
    } else {
        std::string().swap(s);
    }
}
inline void recycle(std::string &s) {
    s.clear();
    release_big(s);
}
inline void take_buf(std::string &s) {
    auto &sp = spare_bufs();
    if (s.capacity() <= 15 && !sp.empty()) {
        s = std::move(sp.back());
        sp.pop_back();
    }
}
