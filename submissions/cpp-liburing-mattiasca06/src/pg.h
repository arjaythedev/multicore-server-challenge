// Non-blocking libpq connection in pipeline mode. All statements are prepared once at connect time.
#pragma once
#include <libpq-fe.h>

#include <cstdint>
#include <deque>
#include <string>

struct PgConn {
    PGconn *c = nullptr;
    int sock = -1;
    bool polling = false;     // multishot POLLIN armed on the ring
    bool want_out = false;    // one-shot POLLOUT armed
    // one entry per pipeline segment in flight (FIFO); `tag` is owned by the caller
    struct Seg {
        uint64_t tag;
        PGresult *res = nullptr;
    };
    std::deque<Seg> inflight;

    // Blocking connect + prepare + SET, then switch to non-blocking pipeline mode. Throws on failure.
    void connect(const char *url);
    // Queue one prepared statement as its own segment (Bind/Execute + Sync). Binary results.
    bool send_prepared(uint64_t tag, const char *stmt, int nparams, const char *const *values,
                       const int *lengths, const int *formats);
    // Returns true if data is left unflushed (arm POLLOUT).
    bool flush();
    // Consume input and collect finished segments; calls done(tag, result-or-null) for each, in order.
    template <class F> void drain(F &&done);
    void close();
};

template <class F> void PgConn::drain(F &&done) {
    if (!PQconsumeInput(c)) {
        while (!inflight.empty()) {
            done(inflight.front().tag, nullptr);
            inflight.pop_front();
        }
        return;
    }
    while (!inflight.empty() && !PQisBusy(c)) {
        PGresult *r = PQgetResult(c);
        if (!r) continue;  // separator after a query's result
        ExecStatusType st = PQresultStatus(r);
        if (st == PGRES_PIPELINE_SYNC) {
            PQclear(r);
            Seg s = inflight.front();
            inflight.pop_front();
            done(s.tag, s.res);
            continue;
        }
        Seg &s = inflight.front();
        if (s.res) PQclear(s.res);  // keep the last result of the segment
        s.res = r;
    }
}
