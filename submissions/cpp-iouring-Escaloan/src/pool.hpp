// Per-event-loop slab allocator. Size classes grow x4 from 1 KiB to 4 MiB. Free lists are LIFO so the most
// recently released (cache-warm) buffer is reused first. Memory comes from 2 MiB mmap chunks advised for
// transparent huge pages. Never touched by more than one thread; no locking.
#pragma once
#include <sys/mman.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <vector>

#include "config.hpp"
#include "util.hpp"

struct SlabPool {
  static constexpr std::size_t class_bytes(int cls) {
    return std::size_t(1) << (cfg::kSlabMinShift + std::size_t(cls) * cfg::kSlabShiftStep);
  }
  // Smallest class that holds n bytes, or -1 if n exceeds the largest class.
  static int class_for(std::size_t n) {
    for (int c = 0; c < cfg::kSlabClasses; ++c)
      if (n <= class_bytes(c)) return c;
    return -1;
  }

  struct ClassState {
    std::vector<char*> free;   // LIFO
    std::size_t held_bytes = 0;  // bytes mapped for this class (in use + free)
    std::size_t in_use = 0;      // buffers handed out
  };
  ClassState classes[cfg::kSlabClasses];
  std::uint64_t exhausted_events = 0;

  SlabPool() {
    for (auto& c : classes) c.free.reserve(4096);
  }
  SlabPool(const SlabPool&) = delete;
  SlabPool& operator=(const SlabPool&) = delete;

  // Returns nullptr when the class is at its cap (caller applies backpressure) or mmap fails.
  char* alloc(int cls) {
    ClassState& c = classes[cls];
    if (UNLIKELY(c.free.empty()) && !refill(cls)) {
      ++exhausted_events;
      return nullptr;
    }
    char* p = c.free.back();
    c.free.pop_back();
    ++c.in_use;
    return p;
  }
  void release(char* p, int cls) {
    ClassState& c = classes[cls];
    --c.in_use;
    c.free.push_back(p);
  }
  // True when every class can still hand out at least `n` more buffers without exceeding its cap.
  bool has_headroom(int cls, std::size_t n) const {
    const ClassState& c = classes[cls];
    if (c.free.size() >= n) return true;
    std::size_t need = (n - c.free.size()) * class_bytes(cls);
    return c.held_bytes + need <= cfg::kSlabClassCapBytes;
  }

 private:
  bool refill(int cls) {
    ClassState& c = classes[cls];
    std::size_t bytes = class_bytes(cls);
    std::size_t chunk = bytes > cfg::kSlabChunkBytes ? bytes : cfg::kSlabChunkBytes;
    if (c.held_bytes + chunk > cfg::kSlabClassCapBytes) return false;
    void* m = mmap(nullptr, chunk, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) {
      util::log("slab mmap(%zu) failed: %s", chunk, std::strerror(errno));
      return false;
    }
    madvise(m, chunk, MADV_HUGEPAGE);
    c.held_bytes += chunk;
    // Push in reverse so the lowest address is handed out first.
    for (std::size_t off = chunk; off >= bytes; off -= bytes) c.free.push_back(static_cast<char*>(m) + off - bytes);
    return true;
  }
};

// A buffer borrowed from a SlabPool. `cls` < 0 means empty.
struct Buf {
  char* p = nullptr;
  std::uint32_t cap = 0;
  std::int8_t cls = -1;

  bool empty() const { return p == nullptr; }
};

// Class marker for a buffer larger than the largest slab class, taken from the heap (rare; counted).
inline constexpr std::int8_t kHeapClass = 127;
inline std::atomic<std::uint64_t> g_heap_fallbacks{0};  // stats only

inline bool buf_alloc(SlabPool& pool, Buf& b, std::size_t min_bytes) {
  int cls = SlabPool::class_for(min_bytes);
  if constexpr (cfg::kHeapBuffers) {
    // Same size classes (same growth behaviour), but each buffer comes from malloc.
    std::size_t bytes = cls >= 0 ? SlabPool::class_bytes(cls) : min_bytes;
    char* h = static_cast<char*>(std::malloc(bytes));
    if (!h) return false;
    b.p = h;
    b.cap = std::uint32_t(bytes);
    b.cls = kHeapClass;
    return true;
  }
  if (cls < 0) {
    if (min_bytes > (std::size_t(1) << 31)) return false;
    char* h = static_cast<char*>(std::malloc(min_bytes));
    if (!h) return false;
    g_heap_fallbacks.fetch_add(1, std::memory_order_relaxed);
    b.p = h;
    b.cap = std::uint32_t(min_bytes);
    b.cls = kHeapClass;
    return true;
  }
  char* p = pool.alloc(cls);
  if (!p) return false;
  b.p = p;
  b.cap = std::uint32_t(SlabPool::class_bytes(cls));
  b.cls = std::int8_t(cls);
  return true;
}
inline void buf_free(SlabPool& pool, Buf& b) {
  if (b.p) {
    if (b.cls == kHeapClass) std::free(b.p);
    else pool.release(b.p, b.cls);
  }
  b = Buf{};
}
