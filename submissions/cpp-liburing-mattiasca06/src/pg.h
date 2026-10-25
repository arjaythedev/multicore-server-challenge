// Non-blocking libpq connection in pipeline mode. All statements are prepared once at connect time.
#pragma once
#include <libpq-fe.h>

#include <cstdint>
#include <deque>
#include <initializer_list>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

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
    std::vector<Param> params;
    Query(const char *s, std::initializer_list<Param> p) : stmt(s), params(p) {}
};

// Owns the results of one pipeline segment (one PGresult per statement).
struct Rows {
    std::vector<PGresult *> r;
    bool ok = true;  // false if the connection failed before the segment completed
    Rows() = default;
    Rows(Rows &&o) noexcept : r(std::move(o.r)), ok(o.ok) { o.r.clear(); }
    Rows &operator=(Rows &&o) noexcept {
        clear();
        r = std::move(o.r);
        ok = o.ok;
        o.r.clear();
        return *this;
    }
    ~Rows() { clear(); }
    void clear() {
        for (PGresult *p : r) PQclear(p);
        r.clear();
    }
    PGresult *operator[](size_t i) const { return r[i]; }
    // True if the segment produced `n` results and every one of them succeeded.
    bool all_ok(size_t n) const {
        if (!ok || r.size() != n) return false;
        for (PGresult *p : r) {
            ExecStatusType st = PQresultStatus(p);
            if (st != PGRES_TUPLES_OK && st != PGRES_COMMAND_OK) return false;
        }
        return true;
    }
};

struct PgConn {
    PGconn *c = nullptr;
    int sock = -1;
    bool want_out = false;  // one-shot POLLOUT armed
    bool in_armed = false;  // one-shot POLLIN armed
    bool dead = false;
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
