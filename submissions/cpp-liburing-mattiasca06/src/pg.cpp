#include "pg.h"

#include <cstdlib>
#include <stdexcept>
#include <string>

#include "sql.h"

void PgConn::connect(const char *url) {
    c = PQconnectdb(url);
    if (PQstatus(c) != CONNECTION_OK) throw std::runtime_error(std::string("postgres: ") + PQerrorMessage(c));
    // Prepared statements reuse one generic plan: re-planning every execution was a large share of backend CPU.
    const char *pcm = getenv("PG_PLAN_CACHE");  // override for A/B runs (auto, force_custom_plan, ...)
    if (!pcm) pcm = "force_generic_plan";
    std::string pcm_sql = std::string("SET plan_cache_mode = ") + pcm;
    // The 200-row tags table is cheaper to seq-scan per planner costs, but that is one scan per listed article;
    // every query here has an index path, so keep the planner off sequential scans.
    const char *seq_sql = getenv("PG_SEQSCAN") ? "SET enable_seqscan = on" : "SET enable_seqscan = off";
    for (const char *sql : {"SET jit = off", "SET max_parallel_workers_per_gather = 0", pcm_sql.c_str(), seq_sql}) {
        PGresult *r = PQexec(c, sql);
        bool ok = PQresultStatus(r) == PGRES_COMMAND_OK;
        PQclear(r);
        if (!ok) throw std::runtime_error(std::string("postgres: ") + sql + ": " + PQerrorMessage(c));
    }
    for (const Stmt &s : kStatements) {
        PGresult *r = PQprepare(c, s.name, s.sql, 0, nullptr);
        bool ok = PQresultStatus(r) == PGRES_COMMAND_OK;
        PQclear(r);
        if (!ok) throw std::runtime_error(std::string("postgres: prepare ") + s.name + ": " + PQerrorMessage(c));
    }
    sock = PQsocket(c);
    if (PQsetnonblocking(c, 1) != 0 || PQenterPipelineMode(c) != 1) throw std::runtime_error("postgres: pipeline mode");
}

bool PgConn::send_segment(void *tag, const std::vector<Query> &qs) {
    thread_local std::vector<const char *> values;
    for (const Query &q : qs) {
        values.clear();
        for (const Param &p : q.params) values.push_back(p.v ? p.v->c_str() : nullptr);
        if (!PQsendQueryPrepared(c, q.stmt, int(values.size()), values.data(), nullptr, nullptr, 1)) {
            dead = true;
            return false;
        }
    }
#if PG_VERSION_NUM >= 170000
    if (!PQsendPipelineSync(c)) {
#else
    if (!PQpipelineSync(c)) {
#endif
        dead = true;
        return false;
    }
    inflight.push_back({tag, {}, false});
    return true;
}

bool PgConn::flush() {
    int rc = PQflush(c);
    if (rc < 0) dead = true;
    return rc == 1;
}

void PgConn::drain(std::vector<Seg> &done) {
    if (!PQconsumeInput(c)) dead = true;
    if (dead) {
        for (Seg &s : inflight) {
            for (PGresult *r : s.res) PQclear(r);
            s.res.clear();
            s.failed = true;
            done.push_back(std::move(s));
        }
        inflight.clear();
        return;
    }
    while (!inflight.empty() && !PQisBusy(c)) {
        PGresult *r = PQgetResult(c);
        if (!r) continue;  // separator after a statement's result
        if (PQresultStatus(r) == PGRES_PIPELINE_SYNC) {
            PQclear(r);
            done.push_back(std::move(inflight.front()));
            inflight.pop_front();
        } else {
            inflight.front().res.push_back(r);
        }
    }
}

void PgConn::close() {
    if (c) PQfinish(c);
    c = nullptr;
}
