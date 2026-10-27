// One statement's result, decoded straight from Postgres wire messages into pooled storage (no libpq).
#pragma once
#include <cstdint>
#include <cstdlib>
#include <new>
#include <string_view>
#include <vector>

enum class PgStatus : uint8_t { Ok, Error, Aborted };  // Aborted: skipped because an earlier statement of the segment failed

// Copy for the short values that dominate result rows: overlapping fixed-size moves, no libc call, never touches a
// byte outside [s, s+n) or [d, d+n).
[[gnu::always_inline]] inline void copy_small(char *d, const char *s, size_t n) {
    if (n >= 8) [[likely]] {
        if (n <= 16) {
            uint64_t a, b;
            __builtin_memcpy(&a, s, 8);
            __builtin_memcpy(&b, s + n - 8, 8);
            __builtin_memcpy(d, &a, 8);
            __builtin_memcpy(d + n - 8, &b, 8);
        } else {
            __builtin_memcpy(d, s, n);
        }
    } else if (n >= 4) {
        uint32_t a, b;
        __builtin_memcpy(&a, s, 4);
        __builtin_memcpy(&b, s + n - 4, 4);
        __builtin_memcpy(d, &a, 4);
        __builtin_memcpy(d + n - 4, &b, 4);
    } else if (n >= 1) {
        d[0] = s[0];
        d[n >> 1] = s[n >> 1];
        d[n - 1] = s[n - 1];
    }
}

struct alignas(64) PgResult {
    struct Fld {
        uint32_t off;
        int32_t len;  // -1: NULL
    };
    PgStatus status = PgStatus::Ok;
    char sqlstate[6] = {};
    int nrows = 0, ncols = 0;
    char *data = nullptr;  // every DataRow payload as received (values are NOT NUL-terminated: use length())
    Fld *f = nullptr;      // nrows * ncols
    size_t dsz = 0, dcap = 0, fsz = 0, fcap = 0;

    PgResult() = default;
    PgResult(const PgResult &) = delete;
    ~PgResult() {
        free(data);
        free(f);
    }

    // Room for `d` more value bytes and `n` more fields, so the per-field appends need no capacity check.
    void reserve_row(size_t d, size_t n) {
        if (dsz + d > dcap) [[unlikely]] grow(data, dcap, dsz + d);
        if (fsz + n > fcap) [[unlikely]] grow(f, fcap, fsz + n);
    }

    bool null(int row, int col) const { return f[size_t(row) * size_t(ncols) + size_t(col)].len < 0; }
    const char *value(int row, int col) const {
        const Fld &x = f[size_t(row) * size_t(ncols) + size_t(col)];
        return x.len < 0 ? "" : data + x.off;
    }
    int length(int row, int col) const {
        int32_t n = f[size_t(row) * size_t(ncols) + size_t(col)].len;
        return n < 0 ? 0 : n;
    }
    std::string_view state() const { return {sqlstate, sqlstate[0] ? size_t(5) : size_t(0)}; }

private:
    template <class T>
    static void grow(T *&buf, size_t &cap, size_t need) {
        size_t nc = cap * 2 > need ? cap * 2 : need;
        if (nc < 256) nc = 256;
        void *p = realloc(buf, nc * sizeof(T));
        if (!p) throw std::bad_alloc();
        buf = static_cast<T *>(p);
        cap = nc;
    }
};

// Results are made and released on the worker thread that owns the connection, so the pool needs no lock. It is a plain
// constant-initialized array (trivially destructible), so access is a bare %fs-relative load: no TLS init guard, no atexit.
struct PgResPool {
    PgResult *s[512];
    uint32_t n;
};
inline constinit thread_local PgResPool g_pgres_pool = {{}, 0};

[[gnu::noinline, gnu::cold]] inline PgResult *pgres_make() { return new PgResult; }
[[gnu::noinline, gnu::cold]] inline void pgres_destroy(PgResult *r) { delete r; }

[[gnu::always_inline]] inline PgResult *pgres_new() {
    PgResPool &p = g_pgres_pool;
    if (p.n == 0) [[unlikely]] return pgres_make();
    return p.s[--p.n];
}
[[gnu::always_inline]] inline void pgres_free(PgResult *r) {
    if (!r) return;
    r->status = PgStatus::Ok;
    r->sqlstate[0] = 0;
    r->nrows = r->ncols = 0;
    r->dsz = r->fsz = 0;
    PgResPool &p = g_pgres_pool;
    if (p.n < 512 && r->dcap <= (1u << 20)) [[likely]] p.s[p.n++] = r;
    else pgres_destroy(r);
}

static_assert(sizeof(PgResult) == 64, "a result header is exactly one cache line");
static_assert(sizeof(PgResult::Fld) == 8, "eight field slots per cache line");
