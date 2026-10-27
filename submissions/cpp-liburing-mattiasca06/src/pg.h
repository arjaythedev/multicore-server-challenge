// Postgres connection speaking the wire protocol directly (extended query, pipelined, binary results). libpq is used
// only to connect, authenticate and prepare the statements; after that its socket is driven by this code.
#pragma once
#include <libpq-fe.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <initializer_list>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "pgres.h"
#include "smallvec.h"

// True when tag arrays come back unsorted from SQL (byte-order collation) and the app sorts them.
extern std::atomic<bool> g_sort_tags_in_app;

// A text-format statement parameter; nullptr is SQL NULL.
struct Param {
    std::optional<std::string> v;
    Param(std::nullptr_t) {}
    Param(std::string_view s) : v(std::string(s)) {}
    Param(const std::string &s) : v(s) {}
    Param(const char *s) : v(std::string(s)) {}
    Param(int64_t n) : v(std::to_string(n)) {}
    Param(int n) : v(std::to_string(n)) {}
};

struct Query {
    const char *stmt;
    SmallVec<Param, 6> params;
    Query(const char *s, std::initializer_list<Param> p) : stmt(s), params(p) {}
};

using QVec = SmallVec<Query, 2>;  // the statements of one request

// One request's view of a result: a row range of a PgResult. A batched statement answers several requests with one
// result (first column = the request's position); each request then sees only its own rows and no ord column.
struct Res {
    PgResult *p = nullptr;
    int lo = 0, n = 0, col0 = 0;
    Res() = default;
    Res(PgResult *r) : p(r), n(r->nrows) {}
    Res(PgResult *r, int lo, int n, int col0) : p(r), lo(lo), n(n), col0(col0) {}
    operator PgResult *() const { return p; }
    int rows() const { return n; }
    bool null(int row, int col) const { return p->null(lo + row, col0 + col); }
    const char *raw(int row, int col) const { return p->value(lo + row, col0 + col); }
    std::string_view text(int row, int col) const {
        return {p->value(lo + row, col0 + col), size_t(p->length(lo + row, col0 + col))};
    }
};

// Results of one pipeline segment, cleared together once every request that shares one has let go of it.
struct ResultSet {
    std::vector<PgResult *> r;
    explicit ResultSet(std::vector<PgResult *> v) : r(std::move(v)) {}
    ResultSet(const ResultSet &) = delete;
    ~ResultSet() {
        for (PgResult *p : r) pgres_free(p);
    }
};

struct Rows {
    SmallVec<Res, 3> r;
    std::shared_ptr<ResultSet> shared;  // when set, owns the PgResults (requests of one segment may point at the same one)
    bool ok = true;  // false if the connection failed before the segment completed
    Rows() = default;
    Rows(Rows &&o) noexcept : r(std::move(o.r)), shared(std::move(o.shared)), ok(o.ok) { o.r.clear(); }
    Rows &operator=(Rows &&o) noexcept {
        clear();
        r = std::move(o.r);
        shared = std::move(o.shared);
        ok = o.ok;
        o.r.clear();
        return *this;
    }
    ~Rows() { clear(); }
    void clear() {
        if (!shared)
            for (Res &x : r) pgres_free(x.p);
        shared.reset();
        r.clear();
    }
    const Res &operator[](size_t i) const { return r[i]; }
    // True if the segment produced `n` results and every one of them succeeded.
    bool all_ok(size_t n) const {
        if (!ok || r.size() != n) return false;
        for (const Res &x : r)
            if (x.p->status != PgStatus::Ok) return false;
        return true;
    }
};

struct alignas(64) PgConn {
    // One entry per pipeline segment in flight; `tag` is owned by the caller.
    struct Seg {
        void *tag;
        std::vector<PgResult *> res;
        bool failed = false;
        bool live = false;
        uint32_t n = 0;  // statements in the segment
    };
    // A connection carries at most one segment at a time (the next goes out only once the last is answered), so this is
    // one slot in place of a queue: no heap blocks to chase on every send and receive.
    struct Slot {
        Seg s;
        bool empty() const { return !s.live; }
        void push_back(Seg &&v) {
            s = std::move(v);
            s.live = true;
        }
        Seg &front() { return s; }
        Seg &back() { return s; }
        void pop_front() { s.live = false; }
        void clear() { s.live = false; }
        Seg *begin() { return &s; }
        Seg *end() { return s.live ? &s + 1 : &s; }
    };

    // Members used on every send and receive come first: the first two cache lines hold all of them.
    int sock = -1;
    bool want_out = false;  // one-shot POLLOUT armed
    bool in_armed = false;  // one-shot POLLIN armed
    bool dead = false;
    bool sending = false;   // an io_uring send of `out` is in flight
    size_t out_len = 0, out_off = 0, in_len = 0;
    PgResult *cur = nullptr;  // result being decoded for the oldest segment
    std::vector<char> in, out;  // size() is the capacity in use; out_len / in_len the filled part
    Slot inflight;
    PGconn *c = nullptr;  // connect-time setup and the final Terminate only

    // Blocking connect + SET + prepare, then switch the socket to non-blocking. Throws on failure.
    void connect(const char *url);
    // Queue statements as one pipeline segment (a single Sync, so one implicit transaction). Binary results.
    bool send_segment(void *tag, const std::vector<Query> &qs);
    // Returns true if data is left unflushed (arm POLLOUT).
    bool flush();
    // Read what the socket has and append finished segments to `done`, in order.
    void drain(std::vector<Seg> &done);
    // io_uring completion of a recv into in[in_len..]: n bytes arrived (<= 0: closed or failed).
    void on_data(long n, std::vector<Seg> &done);
    void close();

private:
    void parse(std::vector<Seg> &done);
    bool on_message(char type, const char *b, size_t n, std::vector<Seg> &done);
};

// SQLSTATE of a failed result ("" if none).
inline std::string_view sqlstate(const PgResult *r) { return r->state(); }
