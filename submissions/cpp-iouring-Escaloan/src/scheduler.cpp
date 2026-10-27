// Query scheduling and Postgres reply handling.
//
// Reads: one FIFO per statement. Once per loop tick (after all completions are drained) every read connection
// with spare depth takes the kind whose oldest request is oldest. GET /api/tags requests already waiting share
// one execution's single row. Writes: one FIFO; a free write connection takes everything queued (up to
// kWriteBatchMax) as one sync group, i.e. one transaction and one WAL flush (group commit). Responses are
// released only after that group's ReadyForQuery.
#include <sys/socket.h>

#include "server.hpp"
#include "util.hpp"

namespace {

void q_push(Loop::Queue& q, Request* r) {
  r->next = nullptr;
  if (q.tail) q.tail->next = r;
  else q.head = r;
  q.tail = r;
  ++q.len;
}

void q_push_front(Loop::Queue& q, Request* r) {
  r->next = q.head;
  q.head = r;
  if (!q.tail) q.tail = r;
  ++q.len;
}

Request* q_pop(Loop::Queue& q) {
  Request* r = q.head;
  if (!r) return nullptr;
  q.head = r->next;
  if (!q.head) q.tail = nullptr;
  r->next = nullptr;
  --q.len;
  return r;
}

void hist_add(Stats& s, std::uint32_t n) {
  int b = n <= 1 ? 0 : n == 2 ? 1 : n <= 4 ? 2 : n <= 8 ? 3 : n <= 16 ? 4 : n <= 32 ? 5 : n <= 64 ? 6 : 7;
  ++s.batch_hist[b];
}

void push_group(PgConn& c, SyncGroup* g) {
  c.groups[(c.g_head + c.g_count) & 7] = g;
  ++c.g_count;
}

// Reset a request whose statement results were partly streamed, so it can run again.
void reset_for_retry(Loop& L, Request* r) {
  (void)L;
  r->out.release();
  r->got_row = false;
  r->flags = 0;
  r->status = 0;
}

void dispatch_writes(Loop& L) {
  for (int i = L.n_read; i < L.n_read + L.n_write; ++i) {
    PgConn& c = *L.pg[std::size_t(i)];
    if (c.state != PgState::Up || c.g_count != 0) continue;
    Loop::Queue* q = L.write_solo_q.head ? &L.write_solo_q : L.write_q.head ? &L.write_q : nullptr;
    if (!q) return;
    SyncGroup* g = group_alloc(L);
    g->is_write = true;
    int max_reqs = q == &L.write_solo_q ? 1 : cfg::kWriteBatchMax;
    while (q->head && int(g->n_reqs) < max_reqs) {
      Request* r = q_pop(*q);
      std::uint8_t stmts[2];
      int n = write_stmts(r, stmts);
      std::uint32_t idx = g->n_reqs++;
      g->reqs[idx] = r;
      for (int k = 0; k < n; ++k) {
        StmtEntry& e = g->entries[g->n_entries++];
        e.stmt = stmts[k];
        e.batched = 0;
        e.nreq = 1;
        e.first = idx;
        pg::Bind b(c.out, stmts[k], sql::kStmts[stmts[k]].nparams);
        encode_params(b, r, stmts[k]);
        b.finish();
      }
    }
    pg::sync(c.out);
    push_group(c, g);
    ++L.stats.write_groups;
    L.stats.write_reqs += g->n_reqs;
    pg_submit_send(L, c);
  }
}

// Batched Bind: parameter k becomes a one-dimensional array holding every request's k-th value.
// `stmt` is the statement to bind: a batchable single-form id (bound as "b<id>") or a shared id ("s<id>").
void encode_batched(pg::PgOut& out, std::uint8_t stmt, Request* const* reqs, std::uint32_t n) {
  int kind = sql::base_kind(stmt);
  const sql::StmtDef& d = sql::kStmts[kind];
  Param ps[kMaxGroupReqs][6];
  for (std::uint32_t i = 0; i < n; ++i) params_of(reqs[i], std::uint8_t(kind), ps[i]);
  pg::Bind b(out, stmt, d.nparams, stmt >= sql::kStmtCount ? 's' : 'b');
  for (int k = 0; k < d.nparams; ++k) {
    bool has_null = false;
    for (std::uint32_t i = 0; i < n; ++i) has_null |= ps[i][k].kind == Param::Null;
    std::size_t at = b.param_begin();
    b.append_be32(1);                      // ndim
    b.append_be32(has_null ? 1 : 0);
    b.append_be32(d.types[k]);             // element type
    b.append_be32(n);                      // dimension length
    b.append_be32(1);                      // lower bound
    for (std::uint32_t i = 0; i < n; ++i) {
      const Param& p = ps[i][k];
      if (p.kind == Param::Null) {
        b.append_be32(0xFFFFFFFFu);
      } else if (p.kind == Param::Int8) {
        b.append_be32(8);
        b.append_be64(std::uint64_t(p.i));
      } else {
        b.append_be32(std::uint32_t(p.s.size()));
        b.append(p.s.data(), p.s.size());
      }
    }
    b.param_end(at);
  }
  b.finish();
}

// The shared form pays for materialising and de-duplicating; use it only when at least half of the requests repeat
// another request's (limit, offset, filter), so distinct pages <= n / 2 (the leader's rule).
bool pages_repeat(Request* const* reqs, std::uint32_t n) {
  std::uint32_t distinct = 0;
  for (std::uint32_t i = 0; i < n; ++i) {
    bool seen = false;
    for (std::uint32_t j = 0; j < i && !seen; ++j)
      seen = reqs[j]->limit == reqs[i]->limit && reqs[j]->offset == reqs[i]->offset && reqs[j]->s[0] == reqs[i]->s[0];
    if (!seen && ++distinct > n / 2) return false;
  }
  return true;
}

int batch_cap(std::uint8_t stmt) {
  if (!cfg::kBatchReads) return 1;
  switch (stmt) {
    case sql::kComments: return cfg::kBatchMaxComments;
    case sql::kListAll:
    case sql::kListTag:
    case sql::kListAuthor:
    case sql::kListFavorited:
    case sql::kListAllDeep: return cfg::kBatchMaxList;
    case sql::kFeed: return cfg::kBatchMaxFeed;
    default: return cfg::kBatchMaxPoint;
  }
}

void dispatch_reads(Loop& L) {
  for (int i = 0; i < L.n_read; ++i) {
    PgConn& c = *L.pg[std::size_t(i)];
    while (c.state == PgState::Up && c.g_count < cfg::kReadDepth) {
      // Oldest head across kinds (FIFO fairness), skipping feed when it is at its in-flight cap.
      int feed_inflight = 0;
      for (int k = 0; k < L.n_read; ++k) feed_inflight += L.pg[std::size_t(k)]->feed_inflight;
      int best = -1;
      std::int64_t best_t = INT64_MAX;
      for (int k = 0; k < sql::kStmtCount; ++k) {
        Request* h = L.read_q[k].head;
        if (!h) continue;
        if (k == sql::kFeed && feed_inflight >= cfg::kFeedMaxInflight) continue;
        if (h->t_start_us < best_t) {
          best_t = h->t_start_us;
          best = k;
        }
      }
      if (best < 0) return;
      std::uint8_t stmt = std::uint8_t(best);
      Loop::Queue& q = L.read_q[best];
      SyncGroup* g = group_alloc(L);
      g->kind = stmt;
      StmtEntry& e = g->entries[g->n_entries++];
      e.stmt = stmt;
      e.first = 0;
      if (stmt == sql::kTags && cfg::kTagsShareExecution) {
        // Everyone already waiting for /api/tags shares this execution's single row (nothing is kept after).
        while (q.head && g->n_reqs < std::uint32_t(kMaxGroupReqs)) g->reqs[g->n_reqs++] = q_pop(q);
        e.batched = 2;
        e.nreq = std::uint16_t(g->n_reqs);
        pg::Bind b(c.out, stmt, 0);
        b.finish();
      } else {
        int cap = sql::batchable(stmt) ? batch_cap(stmt) : 1;
        while (q.head && int(g->n_reqs) < cap) g->reqs[g->n_reqs++] = q_pop(q);
        e.nreq = std::uint16_t(g->n_reqs);
        if (g->n_reqs == 1) {
          e.batched = 0;
          pg::Bind b(c.out, stmt, sql::kStmts[stmt].nparams);
          encode_params(b, g->reqs[0], stmt);
          b.finish();
        } else {
          e.batched = 1;
          int shared = cfg::kListSharedEnrichment ? sql::shared_for(stmt) : -1;
          if (shared >= 0 && pages_repeat(g->reqs, g->n_reqs)) {
            e.stmt = std::uint8_t(shared);
            ++L.stats.shared_batches;
          } else if (stmt == sql::kFeed && cfg::kFeedSharedEnrichment &&
                     int(g->n_reqs) >= cfg::kFeedSharedMinBatch) {
            e.stmt = sql::kFeedShared;
            ++L.stats.shared_batches;
          }
          encode_batched(c.out, e.stmt, g->reqs, g->n_reqs);
          L.stats.batched_reqs += g->n_reqs;
        }
      }
      pg::sync(c.out);
      if (stmt == sql::kFeed) ++c.feed_inflight;
      push_group(c, g);
      ++L.stats.pg_groups;
      hist_add(L.stats, g->n_reqs);
      pg_submit_send(L, c);
    }
  }
}

void complete_group(Loop& L, PgConn& c) {
  SyncGroup* g = c.groups[c.g_head];
  c.g_head = (c.g_head + 1) & 7;
  --c.g_count;
  if (g->kind == sql::kFeed && !g->is_write) --c.feed_inflight;
  if (g->is_write) {
    on_write_group_done(L, *g);
  } else if (g->failed && (std::memcmp(g->sqlstate, "57", 2) == 0 || std::memcmp(g->sqlstate, "08", 2) == 0)) {
    // Server shutdown / connection failure: reads are safe to run again (on a healthy connection).
    for (int k = int(g->n_reqs) - 1; k >= 0; --k) {
      Request* r = g->reqs[k];
      reset_for_retry(L, r);
      q_push_front(L.read_q[r->stmt], r);
    }
  } else {
    for (std::uint32_t i = 0; i < g->n_reqs; ++i) on_read_done(L, g->reqs[i], !g->failed);
  }
  group_free(L, g);
}

void handle_msg(Loop& L, PgConn& c, const char* m, std::size_t n) {
  switch (m[0]) {
    case 'D': {
      if (!c.g_count) return;
      SyncGroup* g = c.groups[c.g_head];
      if (g->failed || g->cur >= g->n_entries) return;
      StmtEntry& e = g->entries[g->cur];
      if (e.batched == 0) {
        Request* r = g->reqs[e.first];
        r->got_row = true;
        pg::Row row = pg::row_of(m, n);
        on_row(L, r, e.stmt, row);
      } else if (e.batched == 2) {
        for (std::uint32_t i = 0; i < e.nreq; ++i) {
          Request* r = g->reqs[e.first + i];
          r->got_row = true;
          pg::Row row = pg::row_of(m, n);
          on_row(L, r, e.stmt, row);
        }
      } else {
        pg::Row row = pg::row_of(m, n);
        const char* v;
        std::int32_t len;
        if (!row.next(v, len) || len != 4) return;
        std::int32_t ord = pg::dec_int4(v);
        if (ord < 1 || ord > e.nreq) return;
        Request* r = g->reqs[e.first + std::uint32_t(ord - 1)];
        r->got_row = true;
        on_row(L, r, e.stmt, row);
      }
      return;
    }
    case 'C': {
      if (!c.g_count) return;
      SyncGroup* g = c.groups[c.g_head];
      if (g->failed || g->cur >= g->n_entries) return;
      StmtEntry& e = g->entries[g->cur];
      for (std::uint32_t i = 0; i < e.nreq; ++i) on_stmt_done(L, g->reqs[e.first + i], e.stmt);
      ++g->cur;
      ++L.stats.pg_stmts;
      return;
    }
    case 'E': {
      char state[6];
      pg::error_sqlstate(m, n, state);
      if (!c.g_count) {
        util::log("loop %d: postgres error outside a request on %d: %s", L.id, c.index, pg::error_message(m, n).c_str());
        return;
      }
      SyncGroup* g = c.groups[c.g_head];
      if (!g->failed) {
        g->failed = true;
        g->fail_entry = g->cur;
        std::memcpy(g->sqlstate, state, 6);
        // Unique violations are expected (register / settings); anything else is worth a log line.
        if (std::memcmp(state, "23505", 5) != 0)
          util::log("loop %d: postgres error (stmt %d): %s", L.id,
                    g->cur < g->n_entries ? int(g->entries[g->cur].stmt) : -1, pg::error_message(m, n).c_str());
      }
      return;
    }
    case 'Z':
      if (c.g_count) complete_group(L, c);
      return;
    default:
      return;  // BindComplete, NoData, notices, parameter status
  }
}

}  // namespace

void enqueue_read(Loop& L, Request* r, std::uint8_t stmt) {
  r->stmt = stmt;
  if (!r->t_start_us) r->t_start_us = util::now_mono_us();
  q_push(L.read_q[stmt], r);
}

void enqueue_write(Loop& L, Request* r, bool solo) {
  if (!r->t_start_us) r->t_start_us = util::now_mono_us();
  q_push(solo ? L.write_solo_q : L.write_q, r);
}

void dispatch(Loop& L) {
  if (L.write_q.head || L.write_solo_q.head) dispatch_writes(L);
  dispatch_reads(L);
}

void pg_process_input(Loop& L, PgConn& c) {
  std::size_t off = 0, need = 0;
  while (c.state == PgState::Up) {
    std::size_t n = pg::frame(c.in + off, c.in_len - off, need);
    if (!n) break;
    handle_msg(L, c, c.in + off, n);
    off += n;
  }
  if (off) {
    std::memmove(c.in, c.in + off, c.in_len - off);
    c.in_len -= off;
  }
  if (need > c.in_cap) {  // a message larger than the buffer: grow to hold it whole
    std::size_t nc = c.in_cap;
    while (nc < need + 64 * 1024) nc *= 2;
    char* p = static_cast<char*>(std::realloc(c.in, nc));
    if (!p) util::die("out of memory (pg recv buffer %zu)", nc);
    c.in = p;
    c.in_cap = nc;
  }
}

void pg_conn_lost(Loop& L, PgConn& c) {
  if (c.state != PgState::Up) return;
  c.state = PgState::Closing;
  ::shutdown(c.fd, SHUT_RDWR);
  // Reads are safe to run again elsewhere; writes whose commit status is unknown fail with 500.
  for (int i = c.g_count - 1; i >= 0; --i) {
    SyncGroup* g = c.groups[(c.g_head + i) & 7];
    if (g->is_write) {
      for (std::uint32_t k = 0; k < g->n_reqs; ++k) respond_error(L, g->reqs[k], 500, "database connection lost");
    } else {
      for (int k = int(g->n_reqs) - 1; k >= 0; --k) {
        Request* r = g->reqs[k];
        reset_for_retry(L, r);
        q_push_front(L.read_q[r->stmt], r);
      }
    }
    group_free(L, g);
  }
  c.g_count = 0;
  c.g_head = 0;
  c.feed_inflight = 0;
}
