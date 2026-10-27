// Postgres access: libpq in pipeline mode, driven by libuv (uv_poll) on the Node event loop. No threads.
//
//  * Two lanes: lane 0 = reads, lane 1 = writes. Each lane owns a few connections; a request goes to the
//    ready connection with the fewest requests in flight. Writes get their own connections so a COMMIT's
//    fsync never stalls reads that are queued behind it on the same socket.
//  * Each request is 1..3 prepared statements followed by its own Sync, so every request is its own
//    implicit transaction (an error in one request cannot abort its neighbours in the pipeline) and its
//    result only completes after the Sync result, i.e. after the commit: rule 6 (committed before respond).
//  * Many requests can be in flight on one connection; their results come back in send order, which is what
//    the FifoRing of in-flight entries encodes.
//  * Every statement returns at most one row with one column (JSON text built by Postgres). The result of
//    the LAST statement of a request is what is handed back; an error in any statement wins.
#pragma once

#include <libpq-fe.h>
#include <uv.h>

#include <cstdint>
#include <cstdio>
#include <deque>
#include <string>
#include <vector>

#include "ring.h"

struct PgParam {
  bool null = false;
  std::string s;
};
struct PgStmtCall {
  int idx = 0;
  std::vector<PgParam> params;
};
struct PgRequest {
  uint32_t id = 0;
  std::vector<PgStmtCall> stmts;
};
// status: 0 = row (data = the JSON/text value), 1 = no row, 2 = error (sqlstate + data = message)
struct PgResult {
  uint32_t id = 0;
  int status = 1;
  std::string data;
  std::string sqlstate;
};

class Pg {
 public:
  using Callback = void (*)(void* ctx, PgResult& r);

  Pg(uv_loop_t* loop, std::string url, std::vector<std::string> sql, int read_conns, int write_conns,
     std::string sslmode, Callback cb, void* ctx)
      : loop_(loop), url_(std::move(url)), sslmode_(std::move(sslmode)), sql_(std::move(sql)), cb_(cb), ctx_(ctx) {
    stmt_ok_.assign(sql_.size(), 1);
    for (size_t i = 0; i < sql_.size(); ++i) names_.push_back("s" + std::to_string(i));
    const int counts[2] = {read_conns, write_conns};
    for (int lane = 0; lane < 2; ++lane)
      for (int i = 0; i < counts[lane]; ++i) conns_[lane].push_back(new Conn(this, lane, i));
    total_ = conns_[0].size() + conns_[1].size();
    for (int lane = 0; lane < 2; ++lane)
      for (Conn* c : conns_[lane]) c->start_connect();
  }

  size_t statement_count() const { return sql_.size(); }

  // Event-loop thread only.
  void submit(int lane, PgRequest&& req) {
    Conn* best = pick(lane);
    if (best == nullptr) {  // every connection is still connecting (or reconnecting): wait for one
      waiting_[lane].push_back(std::move(req));
      return;
    }
    best->send(std::move(req));
  }

 private:
  struct Inflight {
    uint32_t id = 0;
    int n = 0;          // statements in the request
    int got = 0;        // statement results seen so far
    bool error = false;
    bool has_row = false;
    std::string sqlstate, msg, data;
  };

  struct Conn {
    enum State { DEAD, CONNECTING, PREPARING, READY };

    Conn(Pg* o, int l, int i) : owner(o), lane(l), index(i) {}

    Pg* owner;
    int lane;
    int index;
    State state = DEAD;
    PGconn* pg = nullptr;
    uv_poll_t* poll = nullptr;
    bool out_pending = false;  // libpq still holds unsent bytes
    bool armed_write = false;  // poll currently watches for writability
    size_t prep_i = 0;
    int null_streak = 0;
    FifoRing<Inflight> inflight;

    // ---------------- connect ----------------
    void start_connect() {
      if (state != DEAD) return;
      Pg* o = owner;
      const char* keys[] = {"dbname", "sslmode", "gssencmode", "application_name", nullptr};
      const char* vals[] = {o->url_.c_str(), o->sslmode_.c_str(), "disable", "conduit-node", nullptr};
      pg = PQconnectStartParams(keys, vals, 1);  // dbname holding a postgres:// URL is expanded
      if (pg == nullptr) {
        fail("PQconnectStartParams returned null");
        return;
      }
      if (PQstatus(pg) == CONNECTION_BAD) {
        fail(PQerrorMessage(pg));
        return;
      }
      const int fd = PQsocket(pg);
      if (fd < 0) {
        fail("no socket");
        return;
      }
      poll = new uv_poll_t;
      if (uv_poll_init_socket(o->loop_, poll, fd) != 0) {
        delete poll;
        poll = nullptr;
        fail("uv_poll_init_socket failed");
        return;
      }
      poll->data = this;
      state = CONNECTING;
      armed_write = true;
      uv_poll_start(poll, UV_WRITABLE, &Conn::poll_cb);  // libpq: behave as if the last result was WRITING
    }

    void step_connect() {
      switch (PQconnectPoll(pg)) {
        case PGRES_POLLING_READING:
          armed_write = false;
          uv_poll_start(poll, UV_READABLE, &Conn::poll_cb);
          return;
        case PGRES_POLLING_WRITING:
          armed_write = true;
          uv_poll_start(poll, UV_WRITABLE, &Conn::poll_cb);
          return;
        case PGRES_POLLING_OK:
          connected();
          return;
        default:
          fail(PQerrorMessage(pg));
          return;
      }
    }

    void connected() {
      if (PQsetnonblocking(pg, 1) != 0) {
        fail("PQsetnonblocking failed");
        return;
      }
      state = PREPARING;
      prep_i = 0;
      out_pending = false;
      prepare_next();
    }

    // ---------------- prepare every statement (async, one at a time) ----------------
    void prepare_next() {
      Pg* o = owner;
      if (prep_i >= o->sql_.size()) {
        start_pipeline();
        return;
      }
      if (!PQsendPrepare(pg, o->names_[prep_i].c_str(), o->sql_[prep_i].c_str(), 0, nullptr)) {
        fail(PQerrorMessage(pg));
        return;
      }
      if (!flush()) {
        fail("flush failed");
        return;
      }
      arm();
    }

    void on_prepare(int events) {
      if (events & UV_WRITABLE) {
        if (!flush()) {
          fail("flush failed");
          return;
        }
      }
      if (events & UV_READABLE) {
        if (!PQconsumeInput(pg)) {
          fail(PQerrorMessage(pg));
          return;
        }
        while (state == PREPARING && !PQisBusy(pg)) {
          PGresult* r = PQgetResult(pg);
          if (r == nullptr) {  // this statement is done
            ++prep_i;
            prepare_next();
            return;
          }
          if (PQresultStatus(r) != PGRES_COMMAND_OK) {
            const std::string& q = owner->sql_[prep_i];
            std::fprintf(stderr, "[pg] PREPARE of statement s%zu FAILED: %s    sql: %.160s\n", prep_i,
                         PQresultErrorMessage(r), q.c_str());
            owner->stmt_ok_[prep_i] = 0;
          }
          PQclear(r);
        }
      }
      if (state == PREPARING) arm();
    }

    void start_pipeline() {
      if (!PQenterPipelineMode(pg)) {
        fail("PQenterPipelineMode failed");
        return;
      }
      state = READY;
      out_pending = false;
      null_streak = 0;
      arm();
      owner->note_ready();
      owner->pump(lane);
    }

    // ---------------- steady state ----------------
    void on_ready(int events) {
      if (events & UV_WRITABLE) {
        if (!flush()) {
          fail("flush failed");
          return;
        }
        sync_poll();
      }
      if (events & UV_READABLE) {
        if (!PQconsumeInput(pg)) {
          fail(PQerrorMessage(pg));
          return;
        }
        drain();
      }
    }

    void send(PgRequest&& req) {
      Pg* o = owner;
      for (const PgStmtCall& sc : req.stmts) {
        if (sc.idx < 0 || size_t(sc.idx) >= o->sql_.size() || !o->stmt_ok_[size_t(sc.idx)] ||
            sc.params.size() > 32) {
          PgResult r;
          r.id = req.id;
          r.status = 2;
          r.sqlstate = "42P05";
          r.data = "statement unavailable (see the [pg] PREPARE lines in the server log)";
          o->deliver(r);
          return;
        }
      }
      Inflight f;
      f.id = req.id;
      f.n = int(req.stmts.size());
      inflight.push(std::move(f));
      for (const PgStmtCall& sc : req.stmts) {
        const char* vals[32];
        for (size_t k = 0; k < sc.params.size(); ++k) vals[k] = sc.params[k].null ? nullptr : sc.params[k].s.c_str();
        if (!PQsendQueryPrepared(pg, o->names_[size_t(sc.idx)].c_str(), int(sc.params.size()), vals, nullptr,
                                 nullptr, 0)) {
          fail(PQerrorMessage(pg));
          return;
        }
      }
      if (!PQpipelineSync(pg)) {  // one Sync per request: own implicit transaction, flushes the socket
        fail(PQerrorMessage(pg));
        return;
      }
      if (!flush()) {
        fail("flush failed");
        return;
      }
      sync_poll();
    }

    // Consume every result libpq has buffered. Per request: one result per statement (followed by a NULL
    // terminator we simply skip), then a PGRES_PIPELINE_SYNC that completes the request.
    void drain() {
      while (state == READY && pg != nullptr && !inflight.empty()) {
        if (PQisBusy(pg)) break;
        PGresult* r = PQgetResult(pg);
        if (r == nullptr) {
          if (++null_streak > 8) {
            fail("pipeline out of sync");
            return;
          }
          continue;
        }
        null_streak = 0;
        const ExecStatusType st = PQresultStatus(r);
        if (st == PGRES_PIPELINE_SYNC) {
          PQclear(r);
          finish_head();
          continue;
        }
        Inflight& f = inflight.front();
        ++f.got;
        if (st == PGRES_FATAL_ERROR || st == PGRES_BAD_RESPONSE) {
          if (!f.error) {
            f.error = true;
            const char* ss = PQresultErrorField(r, PG_DIAG_SQLSTATE);
            f.sqlstate = ss ? ss : "XX000";
            f.msg = PQresultErrorMessage(r);
          }
        } else if (st == PGRES_PIPELINE_ABORTED) {
          if (!f.error) {
            f.error = true;
            f.sqlstate = "25P02";
            f.msg = "pipeline aborted";
          }
        } else if (f.got == f.n && st == PGRES_TUPLES_OK) {
          if (PQntuples(r) > 0 && !PQgetisnull(r, 0, 0)) {
            f.has_row = true;
            f.data.assign(PQgetvalue(r, 0, 0), size_t(PQgetlength(r, 0, 0)));
          }
        }
        PQclear(r);
      }
    }

    void finish_head() {
      PgResult res;
      {
        Inflight& f = inflight.front();
        res.id = f.id;
        if (f.error) {
          res.status = 2;
          res.sqlstate = std::move(f.sqlstate);
          res.data = std::move(f.msg);
        } else if (f.has_row) {
          res.status = 0;
          res.data = std::move(f.data);
        } else {
          res.status = 1;
        }
      }
      inflight.pop();
      owner->deliver(res);  // may re-enter send()/fail() through JS; drain() re-checks state every iteration
    }

    // ---------------- helpers ----------------
    bool flush() {
      const int r = PQflush(pg);
      if (r < 0) return false;
      out_pending = (r == 1);
      return true;
    }

    void arm() {
      armed_write = out_pending;
      uv_poll_start(poll, UV_READABLE | (out_pending ? UV_WRITABLE : 0), &Conn::poll_cb);
    }

    void sync_poll() {
      if (poll != nullptr && out_pending != armed_write) arm();
    }

    void fail(const char* why) {
      std::fprintf(stderr, "[pg] lane %d conn %d: %s%s", lane, index, why ? why : "?",
                   (why && *why && why[std::char_traits<char>::length(why) - 1] == '\n') ? "" : "\n");
      teardown();
      while (!inflight.empty()) {
        PgResult r;
        r.id = inflight.front().id;
        r.status = 2;
        r.sqlstate = "08006";
        r.data = "connection lost";
        inflight.pop();
        owner->deliver(r);
      }
      schedule_reconnect();
    }

    void teardown() {
      if (poll != nullptr) {
        uv_poll_stop(poll);
        uv_close(reinterpret_cast<uv_handle_t*>(poll), [](uv_handle_t* h) { delete reinterpret_cast<uv_poll_t*>(h); });
        poll = nullptr;
      }
      if (pg != nullptr) {
        PQfinish(pg);
        pg = nullptr;
      }
      if (state == READY) owner->note_lost();
      state = DEAD;
      out_pending = false;
      armed_write = false;
      null_streak = 0;
    }

    void schedule_reconnect() {
      uv_timer_t* t = new uv_timer_t;
      uv_timer_init(owner->loop_, t);
      t->data = this;
      uv_timer_start(
          t,
          [](uv_timer_t* h) {
            Conn* c = static_cast<Conn*>(h->data);
            uv_close(reinterpret_cast<uv_handle_t*>(h), [](uv_handle_t* hh) { delete reinterpret_cast<uv_timer_t*>(hh); });
            c->start_connect();
          },
          500, 0);
    }

    static void poll_cb(uv_poll_t* h, int status, int events) {
      Conn* c = static_cast<Conn*>(h->data);
      if (status < 0) {
        c->fail(uv_strerror(status));
        return;
      }
      switch (c->state) {
        case CONNECTING: c->step_connect(); break;
        case PREPARING: c->on_prepare(events); break;
        case READY: c->on_ready(events); break;
        default: break;
      }
    }
  };

  Conn* pick(int lane) {
    Conn* best = nullptr;
    size_t best_n = 0;
    for (Conn* c : conns_[lane]) {
      if (c->state != Conn::READY) continue;
      const size_t n = c->inflight.size();
      if (best == nullptr || n < best_n) {
        best = c;
        best_n = n;
      }
    }
    return best;
  }

  void pump(int lane) {
    while (!waiting_[lane].empty()) {
      Conn* best = pick(lane);
      if (best == nullptr) return;
      PgRequest r = std::move(waiting_[lane].front());
      waiting_[lane].pop_front();
      best->send(std::move(r));
    }
  }

  void deliver(PgResult& r) { cb_(ctx_, r); }

  void note_ready() {
    ++ready_;
    if (!announced_ && ready_ == total_) {
      announced_ = true;
      std::fprintf(stderr, "[pg] %zu connections ready (%zu read, %zu write), %zu statements prepared\n", total_,
                   conns_[0].size(), conns_[1].size(), sql_.size());
    }
  }
  void note_lost() {
    if (ready_ > 0) --ready_;
  }

  uv_loop_t* loop_;
  std::string url_;
  std::string sslmode_;
  std::vector<std::string> sql_;
  std::vector<std::string> names_;
  std::vector<char> stmt_ok_;
  Callback cb_;
  void* ctx_;
  std::vector<Conn*> conns_[2];
  std::deque<PgRequest> waiting_[2];
  size_t total_ = 0;
  size_t ready_ = 0;
  bool announced_ = false;
};
