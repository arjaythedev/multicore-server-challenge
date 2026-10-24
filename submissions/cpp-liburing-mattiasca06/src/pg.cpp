#include "pg.h"

#include <stdexcept>

static const char *const kStatements[][2] = {
    {"tags", "SELECT name FROM tags ORDER BY name"},
};

void PgConn::connect(const char *url) {
    c = PQconnectdb(url);
    if (PQstatus(c) != CONNECTION_OK) throw std::runtime_error(std::string("postgres: ") + PQerrorMessage(c));
    for (const char *sql : {"SET jit = off", "SET max_parallel_workers_per_gather = 0"}) {
        PGresult *r = PQexec(c, sql);
        bool ok = PQresultStatus(r) == PGRES_COMMAND_OK;
        PQclear(r);
        if (!ok) throw std::runtime_error(std::string("postgres: ") + sql + ": " + PQerrorMessage(c));
    }
    for (auto &s : kStatements) {
        PGresult *r = PQprepare(c, s[0], s[1], 0, nullptr);
        bool ok = PQresultStatus(r) == PGRES_COMMAND_OK;
        PQclear(r);
        if (!ok) throw std::runtime_error(std::string("postgres: prepare ") + s[0] + ": " + PQerrorMessage(c));
    }
    sock = PQsocket(c);
    if (PQsetnonblocking(c, 1) != 0 || PQenterPipelineMode(c) != 1) throw std::runtime_error("postgres: pipeline mode");
}

bool PgConn::send_prepared(uint64_t tag, const char *stmt, int nparams, const char *const *values,
                           const int *lengths, const int *formats) {
    if (!PQsendQueryPrepared(c, stmt, nparams, values, lengths, formats, 1)) return false;
#if PG_VERSION_NUM >= 170000
    if (!PQsendPipelineSync(c)) return false;
#else
    if (!PQpipelineSync(c)) return false;
#endif
    inflight.push_back({tag, nullptr});
    return true;
}

bool PgConn::flush() { return PQflush(c) == 1; }

void PgConn::close() {
    if (c) PQfinish(c);
    c = nullptr;
}
