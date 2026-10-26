// Non-blocking libpq connection in pipeline mode. All statements are prepared once at connect time.
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

// One request's view of a result: a row range of a PGresult. A batched statement answers several requests with one
// result (first column = the request's position); each request then sees only its own rows and no ord column.
struct Res {
    PGresult *p = nullptr;
    int lo = 0, n = 0, col0 = 0;
    Res() = default;
    Res(PGresult *r) : p(r), n(PQntuples(r)) {}
    Res(PGresult *r, int lo, int n, int col0) : p(r), lo(lo), n(n), col0(col0) {}
    operator PGresult *() const { return p; }
    int rows() const { return n; }
    bool null(int row, int col) const { return PQgetisnull(p, lo + row, col0 + col) != 0; }
    const char *raw(int row, int col) const { return PQgetvalue(p, lo + row, col0 + col); }
    std::string_view text(int row, int col) const {
        return {PQgetvalue(p, lo + row, col0 + col), size_t(PQgetlength(p, lo + row, col0 + col))};
    }
};

// Results of one pipeline segment, cleared together once every request that shares one has let go of it.
struct ResultSet {
    std::vector<PGresult *> r;
    explicit ResultSet(std::vector<PGresult *> v) : r(std::move(v)) {}
    ResultSet(const ResultSet &) = delete;
    ~ResultSet() {
        for (PGresult *p : r) PQclear(p);
    }
};

struct Rows {
    SmallVec<Res, 3> r;
    std::shared_ptr<ResultSet> shared;  // when set, owns the PGresults (requests of one segment may point at the same one)
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
            for (Res &x : r) PQclear(x.p);
        shared.reset();
        r.clear();
    }
    const Res &operator[](size_t i) const { return r[i]; }
    // True if the segment produced `n` results and every one of them succeeded.
    bool all_ok(size_t n) const {
        if (!ok || r.size() != n) return false;
        for (const Res &x : r) {
            ExecStatusType st = PQresultStatus(x.p);
            if (st != PGRES_TUPLES_OK && st != PGRES_COMMAND_OK) return false;
        }
        return true;
    }
};

struct alignas(64) PgConn {
    PGconn *c = nullptr;
    int sock = -1;
    bool want_out = false;  // one-shot POLLOUT armed
    bool in_armed = false;  // one-shot POLLIN armed
    bool dead = false;
    bool maybe_ready = false;  // queried or flushed since the last check: libpq may have read results while writing
    // One entry per pipeline segment in flight (FIFO); `tag` is owned by the caller.
    struct Seg {
        void *tag;
        std::vector<PGresult *> res;
        bool failed = false;
    };
    std::deque<Seg> inflight;

    // Blocking connect + SET + prepare, then switch to non-blocking pipeline mode. Throws on failure.
    void connect(const char *url);
    // Queue statements as one pipeline segment (a single Sync, so one implicit transaction). Binary results.
    bool send_segment(void *tag, const std::vector<Query> &qs);
    // Returns true if data is left unflushed (arm POLLOUT).
    bool flush();
    // Consume input and append finished segments to `done`, in order.
    void drain(std::vector<Seg> &done);
    void close();
};

// SQLSTATE of a failed result ("" if none).
inline std::string_view sqlstate(PGresult *r) {
    const char *s = PQresultErrorField(r, PG_DIAG_SQLSTATE);
    return s ? s : "";
}
