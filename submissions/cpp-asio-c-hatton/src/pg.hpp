// Postgres client: libpq in pipeline mode on a non-blocking socket, driven by the worker's Asio reactor.
//
// Every request sends its statements (prepared, binary results) followed by one Sync, without waiting for
// earlier requests on the same connection. A request's statements therefore run as one implicit transaction,
// and the callback fires once the Sync comes back (i.e. after the commit). Output is flushed once per event
// loop turn, so all requests issued in one turn go out in a single write.
#pragma once
#include <libpq-fe.h>

#include <boost/asio.hpp>
#include <boost/container/small_vector.hpp>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "util.hpp"

namespace asio = boost::asio;

// One statement's result, binary format.
struct Res {
  PGresult* r = nullptr;
  int rows() const { return PQntuples(r); }
  bool null(int row, int col) const { return PQgetisnull(r, row, col); }
  std::string_view str(int row, int col) const {
    return {PQgetvalue(r, row, col), size_t(PQgetlength(r, row, col))};
  }
  int64_t i64(int row, int col) const { return be64(PQgetvalue(r, row, col)); }
  bool b(int row, int col) const { return PQgetvalue(r, row, col)[0] != 0; }
};

struct PgResults {
  static constexpr int kMax = 6;
  int n = 0;
  Res res[kMax];
  bool ok = true;
  char sqlstate[6] = {0};
  const Res& operator[](int i) const { return res[i]; }
  bool unique_violation() const { return std::string_view(sqlstate) == "23505"; }
  void clear() {
    for (int i = 0; i < n; ++i) PQclear(res[i].r);
    n = 0;
  }
};

using PgCallback = std::function<void(PgResults&)>;

// A statement to send: prepared statement index and text parameters (nullptr = SQL NULL).
struct Stmt {
  int id;
  int nparams;
  const char* const* params;
};

class PgConn {
 public:
  // batch: group commit. Write requests that arrive while a transaction is in flight wait and then go out
  // together as one transaction (one Sync, one WAL flush). If that transaction fails, each of its requests is
  // retried in a transaction of its own, so one request's error (a unique violation, say) never fails another.
  PgConn(asio::io_context& io, const std::string& conninfo, const std::vector<std::string>& sql,
         const std::vector<std::string>& setup, bool batch)
      : io_(io), sd_(io), batch_(batch) {
    c_ = PQconnectdb(conninfo.c_str());
    if (PQstatus(c_) != CONNECTION_OK) die("connect", PQerrorMessage(c_));
    for (auto& s : setup) {
      PGresult* r = PQexec(c_, s.c_str());
      if (PQresultStatus(r) != PGRES_COMMAND_OK && PQresultStatus(r) != PGRES_TUPLES_OK) die(s.c_str(), PQerrorMessage(c_));
      PQclear(r);
    }
    for (size_t i = 0; i < sql.size(); ++i) {
      std::string name = "s" + std::to_string(i);
      PGresult* r = PQprepare(c_, name.c_str(), sql[i].c_str(), 0, nullptr);
      if (PQresultStatus(r) != PGRES_COMMAND_OK) {
        std::fprintf(stderr, "prepare failed:\n%s\n", sql[i].c_str());
        die("prepare", PQerrorMessage(c_));
      }
      PQclear(r);
      names_.push_back(name);
    }
    if (PQsetnonblocking(c_, 1) != 0) die("nonblocking", PQerrorMessage(c_));
    if (PQenterPipelineMode(c_) != 1) die("pipeline", PQerrorMessage(c_));
    sd_.assign(PQsocket(c_));
  }

  ~PgConn() {
    sd_.release();
    PQfinish(c_);
  }

  size_t pending() const { return inflight_.size() + waiting_.size(); }

  void exec(std::initializer_list<Stmt> stmts, PgCallback cb) { exec(stmts.begin(), stmts.size(), std::move(cb)); }

  void exec(const Stmt* stmts, size_t n, PgCallback cb) {
    auto r = std::make_unique<Req>();
    r->cb = std::move(cb);
    r->nstmts = int(n);
    if (dead_) return fail_req(*r);
    if (!batch_) {
      if (!send_stmts(stmts, n) || !sync()) return fail_req(*r);
      Group g;
      g.reqs.push_back(std::move(r));
      inflight_.push_back(std::move(g));
      kick();
      return;
    }
    // Parameters are copied: a batched request may be sent later, or twice.
    r->owned.resize(n);
    for (size_t i = 0; i < n; ++i) {
      auto& o = r->owned[i];
      o.id = stmts[i].id;
      for (int k = 0; k < stmts[i].nparams; ++k) {
        const char* v = stmts[i].params[k];
        o.isnull.push_back(v == nullptr);
        o.vals.emplace_back(v ? v : "");
      }
    }
    waiting_.push_back(std::move(r));
    if (inflight_.empty()) send_waiting();
  }

 private:
  struct OwnedStmt {
    int id;
    std::vector<std::string> vals;
    std::vector<char> isnull;
  };
  struct Req {
    PgCallback cb;
    PgResults res;
    int nstmts = 0, got = 0;
    std::vector<OwnedStmt> owned;
  };
  struct Group {  // requests sharing one Sync, i.e. one transaction
    boost::container::small_vector<std::unique_ptr<Req>, 1> reqs;
    size_t cur = 0;
    bool ok = true;
  };

  [[noreturn]] static void die(const char* what, const char* msg) {
    std::fprintf(stderr, "postgres %s: %s\n", what, msg);
    std::exit(1);
  }

  static void fail_req(Req& r) {
    r.res.clear();
    r.res.ok = false;
    r.cb(r.res);
  }

  bool send_stmts(const Stmt* stmts, size_t n) {
    for (size_t i = 0; i < n; ++i) {
      const Stmt& s = stmts[i];
      if (!PQsendQueryPrepared(c_, names_[s.id].c_str(), s.nparams, s.params, nullptr, nullptr, 1)) {
        fail(PQerrorMessage(c_));
        return false;
      }
    }
    return true;
  }

  bool send_owned(const Req& r) {
    const char* p[16];
    for (auto& o : r.owned) {
      int np = int(o.vals.size());
      for (int k = 0; k < np && k < 16; ++k) p[k] = o.isnull[k] ? nullptr : o.vals[k].c_str();
      Stmt s{o.id, np, p};
      if (!send_stmts(&s, 1)) return false;
    }
    return true;
  }

  bool sync() {
    if (!PQpipelineSync(c_)) {
      fail(PQerrorMessage(c_));
      return false;
    }
    return true;
  }

  void send_waiting() {
    Group g;
    while (!waiting_.empty() && g.reqs.size() < 256) {
      g.reqs.push_back(std::move(waiting_.front()));
      waiting_.pop_front();
      if (!send_owned(*g.reqs.back())) break;
    }
    if (dead_ || !sync()) {
      for (auto& r : g.reqs) fail_req(*r);
      return;
    }
    inflight_.push_back(std::move(g));
    kick();
  }

  void send_solo(std::unique_ptr<Req> r) {
    r->res.clear();
    r->res = PgResults{};
    r->got = 0;
    if (!send_owned(*r) || !sync()) return fail_req(*r);
    Group g;
    g.reqs.push_back(std::move(r));
    inflight_.push_back(std::move(g));
    kick();
  }

  void kick() {
    if (!flush_posted_) {
      flush_posted_ = true;
      asio::post(io_, [this] {
        flush_posted_ = false;
        flush();
      });
    }
    arm_read();
  }

  void fail(const char* msg) {
    if (dead_) return;
    std::fprintf(stderr, "postgres connection failed: %s\n", msg);
    dead_ = true;
    auto inflight = std::move(inflight_);
    auto waiting = std::move(waiting_);
    for (auto& g : inflight)
      for (auto& r : g.reqs) fail_req(*r);
    for (auto& r : waiting) fail_req(*r);
  }

  void flush() {
    if (dead_) return;
    int r = PQflush(c_);
    if (r < 0) return fail(PQerrorMessage(c_));
    if (r == 1 && !writing_) {
      writing_ = true;
      sd_.async_wait(asio::posix::descriptor_base::wait_write, [this](boost::system::error_code ec) {
        writing_ = false;
        if (!ec) flush();
      });
    }
  }

  void arm_read() {
    if (reading_ || dead_ || inflight_.empty()) return;
    reading_ = true;
    sd_.async_wait(asio::posix::descriptor_base::wait_read, [this](boost::system::error_code ec) {
      reading_ = false;
      if (ec) return;
      if (!PQconsumeInput(c_)) return fail(PQerrorMessage(c_));
      process();
      arm_read();
    });
  }

  void finish_group() {
    Group g = std::move(inflight_.front());
    inflight_.pop_front();
    if (g.ok || g.reqs.size() == 1) {
      for (auto& r : g.reqs) {
        r->cb(r->res);
        r->res.clear();
      }
    } else {
      for (auto& r : g.reqs) send_solo(std::move(r));
    }
    if (batch_ && inflight_.empty() && !waiting_.empty() && !dead_) send_waiting();
  }

  void process() {
    while (!inflight_.empty() && !dead_) {
      if (PQisBusy(c_)) break;
      PGresult* r = PQgetResult(c_);
      if (!r) continue;  // end of one statement's results
      Group& g = inflight_.front();
      ExecStatusType st = PQresultStatus(r);
      if (st == PGRES_PIPELINE_SYNC) {
        PQclear(r);
        finish_group();
        continue;
      }
      if (g.cur >= g.reqs.size()) {  // more results than statements: can't happen
        PQclear(r);
        continue;
      }
      Req& q = *g.reqs[g.cur];
      if (st == PGRES_FATAL_ERROR || st == PGRES_PIPELINE_ABORTED) {
        if (q.res.ok && st == PGRES_FATAL_ERROR) {
          const char* code = PQresultErrorField(r, PG_DIAG_SQLSTATE);
          if (code) std::snprintf(q.res.sqlstate, sizeof q.res.sqlstate, "%s", code);
          if ((!code || std::string_view(code) != "23505") && g.reqs.size() == 1)
            std::fprintf(stderr, "postgres error: %s", PQresultErrorMessage(r));
        }
        q.res.ok = false;
        g.ok = false;
      }
      if (q.res.n < PgResults::kMax) q.res.res[q.res.n++].r = r;
      else PQclear(r);
      if (++q.got == q.nstmts) ++g.cur;
    }
    // The connection may have more output queued that the server is now ready to take.
    if (!dead_ && !flush_posted_ && !writing_) flush();
  }

  asio::io_context& io_;
  asio::posix::stream_descriptor sd_;
  bool batch_;
  PGconn* c_ = nullptr;
  std::vector<std::string> names_;
  std::deque<Group> inflight_;
  std::deque<std::unique_ptr<Req>> waiting_;
  bool reading_ = false, writing_ = false, flush_posted_ = false, dead_ = false;
};

// The connections owned by one worker thread; requests go to the connection with the fewest in flight.
class PgPool {
 public:
  void add(std::unique_ptr<PgConn> c) { conns_.push_back(std::move(c)); }
  PgConn& pick() {
    PgConn* best = conns_[next_].get();
    size_t n = conns_.size();
    size_t start = next_;
    next_ = (next_ + 1) % n;
    for (size_t i = 1; i < n && best->pending(); ++i) {
      PgConn* c = conns_[(start + i) % n].get();
      if (c->pending() < best->pending()) best = c;
    }
    return *best;
  }

 private:
  std::vector<std::unique_ptr<PgConn>> conns_;
  size_t next_ = 0;
};
