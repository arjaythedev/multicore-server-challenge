// A thin layer over libpq in pipeline mode: binary parameters and results, all statements of a round trip sent
// before one Sync, a non-blocking socket polled by the connection's own thread.
#pragma once
#include <libpq-fe.h>
#include <poll.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace pq {

enum Type : unsigned { INT8 = 20, INT4 = 23, TEXT = 25, INT8ARR = 1016, TEXTARR = 1009 };

inline int64_t be64(const char *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return (int64_t)__builtin_bswap64(v);
}
inline int32_t be32(const char *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return (int32_t)__builtin_bswap32(v);
}
inline void put32(std::string &b, uint32_t v) { v = __builtin_bswap32(v); b.append((const char *)&v, 4); }
inline void put64(std::string &b, uint64_t v) { v = __builtin_bswap64(v); b.append((const char *)&v, 8); }

// The parameters of one statement, stored in one buffer (binary format).
struct Params {
  std::string buf;
  std::vector<size_t> off;  // offset into buf, or npos for NULL
  std::vector<int> len, fmt;
  std::vector<const char *> ptr;
  void clear() { buf.clear(); off.clear(); len.clear(); fmt.clear(); }
  void begin(size_t n) { size_t s = buf.size(); off.push_back(s); (void)n; }
  void end() { len.push_back((int)(buf.size() - off.back())); fmt.push_back(1); }
  void i64(int64_t v) { begin(8); put64(buf, (uint64_t)v); end(); }
  void text(std::string_view s) { begin(s.size()); buf.append(s.data(), s.size()); end(); }
  void textOpt(const std::optional<std::string> &s) {
    if (s) text(*s);
    else { off.push_back(std::string::npos); len.push_back(0); fmt.push_back(1); }
  }
  template <class V> void i64arr(const V &v) {
    begin(0);
    put32(buf, 1); put32(buf, 0); put32(buf, INT8); put32(buf, (uint32_t)v.size()); put32(buf, 1);
    for (int64_t x : v) { put32(buf, 8); put64(buf, (uint64_t)x); }
    end();
  }
  template <class V> void textarr(const V &v) {
    begin(0);
    put32(buf, 1); put32(buf, 0); put32(buf, TEXT); put32(buf, (uint32_t)v.size()); put32(buf, 1);
    for (const auto &x : v) { std::string_view s(x); put32(buf, (uint32_t)s.size()); buf.append(s.data(), s.size()); }
    end();
  }
  const char *const *values() {
    ptr.resize(off.size());
    for (size_t i = 0; i < off.size(); i++) ptr[i] = off[i] == std::string::npos ? nullptr : buf.data() + off[i];
    return ptr.data();
  }
};

struct Stmt {
  const char *name;
  std::string sql;
  std::vector<unsigned> types;
};

// One result set (binary columns)
struct Res {
  PGresult *r = nullptr;
  int n() const { return r ? PQntuples(r) : 0; }
  int64_t i64(int row, int col) const { return be64(PQgetvalue(r, row, col)); }
  int32_t i32(int row, int col) const { return be32(PQgetvalue(r, row, col)); }
  bool null(int row, int col) const { return PQgetisnull(r, row, col); }
  const char *ptr(int row, int col) const { return PQgetvalue(r, row, col); }
  int len(int row, int col) const { return PQgetlength(r, row, col); }
  std::string_view sv(int row, int col) const { return std::string_view(PQgetvalue(r, row, col), (size_t)PQgetlength(r, row, col)); }
  std::string str(int row, int col) const { return std::string(sv(row, col)); }
  bool ok() const { return r && (PQresultStatus(r) == PGRES_TUPLES_OK || PQresultStatus(r) == PGRES_COMMAND_OK); }
  std::string sqlstate() const {
    const char *s = r ? PQresultErrorField(r, PG_DIAG_SQLSTATE) : nullptr;
    return s ? s : "";
  }
  std::string message() const {
    const char *s = r ? PQresultErrorMessage(r) : nullptr;
    return s ? s : "no result";
  }
};

class Conn {
 public:
  PGconn *c = nullptr;
  std::vector<Res> res;  // results of the last round trip, one per statement

  ~Conn() { clear(); if (c) PQfinish(c); }

  // gucs: "-c jit=off -c ..." as the startup options
  bool connect(const std::string &url, const std::string &gucs) {
    if (c) { PQfinish(c); c = nullptr; }
    const char *keys[] = {"dbname", "options", nullptr};
    const char *vals[] = {url.c_str(), gucs.c_str(), nullptr};
    c = PQconnectdbParams(keys, vals, 1);
    if (PQstatus(c) != CONNECTION_OK) { fprintf(stderr, "[db] connect: %s", PQerrorMessage(c)); return false; }
    return true;
  }
  bool prepare(const std::vector<Stmt> &stmts) {
    for (auto &s : stmts) {
      PGresult *r = PQprepare(c, s.name, s.sql.c_str(), (int)s.types.size(), (const ::Oid *)s.types.data());
      bool ok = PQresultStatus(r) == PGRES_COMMAND_OK;
      if (!ok) fprintf(stderr, "[db] prepare %s: %s", s.name, PQresultErrorMessage(r));
      PQclear(r);
      if (!ok) return false;
    }
    if (PQsetnonblocking(c, 1) != 0 || PQenterPipelineMode(c) != 1) { fprintf(stderr, "[db] pipeline: %s", PQerrorMessage(c)); return false; }
    return true;
  }
  bool dead() const { return !c || PQstatus(c) != CONNECTION_OK; }

  bool queue(const char *name, Params &p) {
    return PQsendQueryPrepared(c, name, (int)p.off.size(), p.values(), p.len.data(), p.fmt.data(), 1) == 1;
  }

  // Sends Sync, waits for every queued statement's result; res[i] is statement i's result (an error result, or
  // PGRES_PIPELINE_ABORTED after an earlier error). Returns false if the connection failed.
  bool run(int n) {
    clear();
    res.resize(n);
    if (PQpipelineSync(c) != 1) return false;
    int qi = 0;
    for (;;) {
      if (!await()) return false;
      PGresult *r = PQgetResult(c);
      if (!r) { qi++; continue; }  // end of one statement's results
      ExecStatusType st = PQresultStatus(r);
      if (st == PGRES_PIPELINE_SYNC) { PQclear(r); return qi == n; }
      if (qi < n && !res[qi].r) res[qi].r = r;
      else PQclear(r);
    }
  }
  void clear() {
    for (auto &r : res) if (r.r) PQclear(r.r);
    res.clear();
  }

 private:
  // until a result can be read without blocking
  bool await() {
    for (;;) {
      int f = PQflush(c);
      if (f < 0) return false;
      if (!PQisBusy(c)) return true;
      pollfd p{PQsocket(c), (short)(POLLIN | (f == 1 ? POLLOUT : 0)), 0};
      if (poll(&p, 1, -1) < 0 && errno != EINTR) return false;
      if (p.revents & (POLLIN | POLLERR | POLLHUP)) {
        if (!PQconsumeInput(c)) return false;
      }
    }
  }
};

}  // namespace pq
