// Event loop: io_uring setup, accept, client receive (multishot poll + recv, "Path B"), response send,
// Postgres socket I/O, cross-thread inbox, 1 s housekeeping tick.
#include "loop.hpp"

#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#include <new>

#include "util.hpp"

namespace {

constexpr std::uint32_t kMaxLiveRequests = 1u << 16;  // per loop; beyond this new requests wait

// ---------- connection slots ----------

std::uint32_t slot_alloc(Loop& L) {
  if (L.free_head) {
    std::uint32_t s = L.free_head - 1;
    L.free_head = L.conns[s].next_free;
    return s;
  }
  if (L.conn_hwm == L.conn_cap) return UINT32_MAX;
  std::uint32_t s = L.conn_hwm++;
  new (&L.conns[s]) ClientConn();
  return s;
}

void slot_free(Loop& L, std::uint32_t s) {
  ClientConn& c = L.conns[s];
  c.gen = (c.gen + 1) & 0xFFFFFF;
  c.state = kConnFree;
  c.flags = 0;
  c.fd = -1;
  c.active = nullptr;
  c.carry_len = 0;
  c.next_free = L.free_head;
  L.free_head = s + 1;
  --L.open_conns;
  ++L.stats.closes;
}

void arm_poll(Loop& L, std::uint32_t slot) {
  ClientConn& c = L.conns[slot];
  io_uring_sqe* sqe = get_sqe(L);
  io_uring_prep_poll_multishot(sqe, c.fd, POLLIN | POLLRDHUP);
  io_uring_sqe_set_data64(sqe, make_ud(kOpPoll, c.gen, slot));
  c.flags |= kPollArmed;
}

void arm_accept(Loop& L) {
  io_uring_sqe* sqe = get_sqe(L);
  io_uring_prep_multishot_accept(sqe, L.listen_fd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
  io_uring_sqe_set_data64(sqe, make_ud(kOpAccept, 0, 0));
}

void arm_eventfd(Loop& L) {
  io_uring_sqe* sqe = get_sqe(L);
  io_uring_prep_read(sqe, L.event_fd, &L.event_buf, sizeof L.event_buf, 0);
  io_uring_sqe_set_data64(sqe, make_ud(kOpEventfd, 0, 0));
}

void arm_tick(Loop& L) {
  L.tick_ts.tv_sec = 1;
  L.tick_ts.tv_nsec = 0;
  io_uring_sqe* sqe = get_sqe(L);
  io_uring_prep_timeout(sqe, &L.tick_ts, 0, 0);
  io_uring_sqe_set_data64(sqe, make_ud(kOpTick, 0, 0));
}

__kernel_timespec g_accept_retry_ts{0, cfg::kAcceptBackoffMs * 1000000LL};

void close_conn(Loop& L, std::uint32_t slot) {
  ClientConn& c = L.conns[slot];
  if (c.state != kConnOpen) return;
  if (c.active) {  // finish the in-flight response first; its completion closes the socket
    c.flags |= kCloseAfter;
    return;
  }
  if (c.carry_len && c.first_byte_s) --L.partial_conns;
  buf_free(L.pool, c.carry);
  c.carry_len = 0;
  c.first_byte_s = 0;
  if (c.flags & kPollArmed) {
    // The poll holds a file reference: cancel it, close our descriptor now, free the slot on the poll's final
    // completion (generation in user_data discards anything that arrives later).
    io_uring_sqe* sqe = get_sqe(L);
    io_uring_prep_poll_remove(sqe, make_ud(kOpPoll, c.gen, slot));
    io_uring_sqe_set_data64(sqe, make_ud(kOpIgnore, 0, 0));
    ::close(c.fd);
    c.fd = -1;
    c.state = kConnClosing;
  } else {
    ::close(c.fd);
    slot_free(L, slot);
  }
}

// ---------- request input ----------

void start_send(Loop& L, std::uint32_t slot);

// Parses the connection's buffered bytes (carry) or `data` and starts at most one request.
// Returns true if a request was started (the connection is then busy until its response is sent).
bool feed(Loop& L, std::uint32_t slot, const char* data, std::size_t n) {
  ClientConn& c = L.conns[slot];
  const char* src = data;
  std::size_t len = n;
  if (c.carry_len) {
    // Append to the carry buffer, growing it as needed.
    std::size_t need = c.carry_len + n;
    if (need > c.carry.cap) {
      Buf nb;
      if (!buf_alloc(L.pool, nb, need)) {
        close_conn(L, slot);
        return false;
      }
      std::memcpy(nb.p, c.carry.p, c.carry_len);
      buf_free(L.pool, c.carry);
      c.carry = nb;
    }
    if (n) std::memcpy(c.carry.p + c.carry_len, data, n);
    c.carry_len = std::uint32_t(need);
    src = c.carry.p;
    len = c.carry_len;
  }
  if (len == 0) return false;

  http::Request hr;
  http::ParseStatus st = http::parse_request(src, len, hr);
  if (st == http::ParseStatus::Incomplete) {
    if (!c.carry_len) {  // keep the partial bytes
      if (c.carry.empty() && !buf_alloc(L.pool, c.carry, len < 4096 ? 4096 : len)) {
        close_conn(L, slot);
        return false;
      }
      if (c.carry.cap < len) {  // existing carry too small (it was emptied but kept)
        buf_free(L.pool, c.carry);
        if (!buf_alloc(L.pool, c.carry, len)) {
          close_conn(L, slot);
          return false;
        }
      }
      std::memcpy(c.carry.p, src, len);
      c.carry_len = std::uint32_t(len);
    }
    if (!c.first_byte_s) {
      c.first_byte_s = std::uint32_t(L.now_s);
      ++L.partial_conns;
    }
    return false;
  }
  if (c.first_byte_s) {
    c.first_byte_s = 0;
    --L.partial_conns;
  }
  if (st != http::ParseStatus::Complete) {
    Request* r = request_alloc(L);
    if (!r) {
      close_conn(L, slot);
      return false;
    }
    r->slot = slot;
    r->keep_alive = false;
    c.active = r;
    c.carry_len = 0;
    int status = st == http::ParseStatus::HeaderTooBig ? 431 : st == http::ParseStatus::BodyTooBig ? 413 : 400;
    respond_error(L, r, status, status == 431 ? "header too large" : status == 413 ? "body too large" : "bad request");
    return true;
  }
  handle_http(L, c, slot, hr, src);  // copies what it needs; sets c.active
  if (c.state != kConnOpen) return true;
  if (!c.active) {  // no request could be allocated: drop the connection
    c.flags &= std::uint8_t(~kCloseAfter);
    close_conn(L, slot);
    return true;
  }
  // Keep any pipelined bytes after this request for later.
  std::size_t rest = len - hr.total_len;
  if (rest) {
    if (c.carry_len) {
      std::memmove(c.carry.p, c.carry.p + hr.total_len, rest);
    } else {
      if (c.carry.empty() || c.carry.cap < rest) {
        buf_free(L.pool, c.carry);
        if (!buf_alloc(L.pool, c.carry, rest < 4096 ? 4096 : rest)) {
          c.flags |= kCloseAfter;
          return true;
        }
      }
      std::memcpy(c.carry.p, src + hr.total_len, rest);
    }
    c.carry_len = std::uint32_t(rest);
  } else {
    c.carry_len = 0;
  }
  return true;
}

void do_read(Loop& L, std::uint32_t slot) {
  ClientConn& c = L.conns[slot];
  if (L.paused) {
    if (!(c.flags & kPausedListed)) {
      c.flags |= kPausedListed;
      L.paused_list.push_back((std::uint64_t(c.gen) << 32) | slot);
    }
    return;
  }
  for (;;) {
    ssize_t n = ::recv(c.fd, L.scratch, cfg::kRecvScratchBytes, MSG_DONTWAIT);
    if (n > 0) {
      c.flags &= std::uint8_t(~kReadPending);
      bool full = std::size_t(n) == cfg::kRecvScratchBytes;
      bool started = feed(L, slot, L.scratch, std::size_t(n));
      if (c.state != kConnOpen) return;
      if (full) c.flags |= kReadPending;
      // A short read means the socket is drained; new bytes raise a new poll notification.
      if (started || !full) return;
      continue;
    }
    if (n == 0) {  // peer closed
      close_conn(L, slot);
      return;
    }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      c.flags &= std::uint8_t(~kReadPending);
      return;
    }
    close_conn(L, slot);
    return;
  }
}

// After a response is fully sent: next pipelined request, pending socket bytes, or close.
void after_response(Loop& L, std::uint32_t slot) {
  ClientConn& c = L.conns[slot];
  if (c.flags & kCloseAfter) {
    close_conn(L, slot);
    return;
  }
  if (c.carry_len) {
    if (feed(L, slot, nullptr, 0)) return;
    if (c.state != kConnOpen) return;
  }
  if (c.flags & kReadPending) do_read(L, slot);
}

void resume_paused(Loop& L) {
  if (L.paused_list.empty()) return;
  std::vector<std::uint64_t> list;
  list.swap(L.paused_list);
  for (std::uint64_t e : list) {
    std::uint32_t slot = std::uint32_t(e), gen = std::uint32_t(e >> 32);
    if (slot >= L.conn_hwm) continue;
    ClientConn& c = L.conns[slot];
    if (c.gen != gen || c.state != kConnOpen) continue;
    c.flags &= std::uint8_t(~kPausedListed);
    if (!c.active) do_read(L, slot);
    if (L.paused) break;
  }
}

// ---------- send ----------

void start_send(Loop& L, std::uint32_t slot) {
  ClientConn& c = L.conns[slot];
  Request* r = c.active;
  std::size_t total = r->out.len - r->send_start;
  io_uring_sqe* sqe = get_sqe(L);
  io_uring_prep_send(sqe, c.fd, r->out.buf.p + r->send_start + c.send_off, total - c.send_off, MSG_NOSIGNAL);
  io_uring_sqe_set_data64(sqe, make_ud(kOpSend, c.gen, slot));
  c.flags |= kSending;
}

void on_send(Loop& L, std::uint32_t slot, std::uint32_t gen, int res) {
  ClientConn& c = L.conns[slot];
  if (c.gen != gen || !c.active) return;
  c.flags &= std::uint8_t(~kSending);
  Request* r = c.active;
  if (res < 0) {
    if (res == -EINTR || res == -EAGAIN) {
      start_send(L, slot);
      return;
    }
    c.active = nullptr;
    request_free(L, r);
    if (c.state == kConnOpen) {
      c.flags &= std::uint8_t(~kCloseAfter);
      close_conn(L, slot);
    }
    return;
  }
  c.send_off += std::uint32_t(res);
  if (c.send_off < r->out.len - r->send_start) {
    start_send(L, slot);
    return;
  }
  bool close = !r->keep_alive;
  c.active = nullptr;
  c.send_off = 0;
  request_free(L, r);
  if (close) c.flags |= kCloseAfter;
  if (c.state == kConnOpen) after_response(L, slot);
}

// ---------- accept ----------

void on_accept(Loop& L, io_uring_cqe* cqe) {
  if (!(cqe->flags & IORING_CQE_F_MORE)) {
    if (cqe->res == -EMFILE || cqe->res == -ENFILE || cqe->res == -ENOBUFS || cqe->res == -ENOMEM) {
      static thread_local std::int64_t last_log = 0;
      if (L.now_s - last_log >= 10) {
        util::log("loop %d: accept: %s (backing off %d ms)", L.id, std::strerror(-cqe->res), cfg::kAcceptBackoffMs);
        last_log = L.now_s;
      }
      io_uring_sqe* sqe = get_sqe(L);
      io_uring_prep_timeout(sqe, &g_accept_retry_ts, 0, 0);
      io_uring_sqe_set_data64(sqe, make_ud(kOpAcceptRetry, 0, 0));
    } else {
      arm_accept(L);
    }
  }
  int fd = cqe->res;
  if (fd < 0) return;
  std::uint32_t slot = slot_alloc(L);
  if (slot == UINT32_MAX) {
    ::close(fd);
    return;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  ClientConn& c = L.conns[slot];
  c.fd = fd;
  c.state = kConnOpen;
  c.flags = 0;
  c.carry_len = 0;
  c.active = nullptr;
  c.send_off = 0;
  c.first_byte_s = 0;
  ++L.open_conns;
  ++L.stats.accepts;
  arm_poll(L, slot);
}

void on_poll(Loop& L, std::uint32_t slot, std::uint32_t gen, io_uring_cqe* cqe) {
  if (slot >= L.conn_hwm) return;
  ClientConn& c = L.conns[slot];
  if (c.gen != gen) return;
  bool more = cqe->flags & IORING_CQE_F_MORE;
  if (!more) {
    c.flags &= std::uint8_t(~kPollArmed);
    if (c.state == kConnClosing) {
      slot_free(L, slot);
      return;
    }
  }
  if (c.state != kConnOpen) return;
  if (cqe->res < 0) {
    if (cqe->res != -ECANCELED) {
      close_conn(L, slot);
      return;
    }
  } else if (c.active) {
    c.flags |= kReadPending;  // read after the current response
  } else {
    do_read(L, slot);
  }
  if (c.state == kConnOpen && !(c.flags & kPollArmed)) arm_poll(L, slot);
}

// ---------- postgres sockets ----------

void pg_arm_recv(Loop& L, PgConn& c) {
  if (c.in_cap - c.in_len < 64 * 1024) {
    std::size_t nc = c.in_cap ? c.in_cap * 2 : cfg::kPgRecvBufInitial;
    while (nc - c.in_len < 64 * 1024) nc *= 2;
    char* n = static_cast<char*>(std::realloc(c.in, nc));
    if (!n) util::die("out of memory (pg recv buffer)");
    c.in = n;
    c.in_cap = nc;
  }
  io_uring_sqe* sqe = get_sqe(L);
  io_uring_prep_recv(sqe, c.fd, c.in + c.in_len, c.in_cap - c.in_len, 0);
  io_uring_sqe_set_data64(sqe, make_ud(kOpPgRecv, c.gen, c.index));
  c.recv_inflight = true;
}

void pg_maybe_finish_close(Loop& L, PgConn& c) {
  if (c.state != PgState::Closing || c.recv_inflight || c.out.inflight_end) return;
  ::close(c.fd);
  c.fd = -1;
  c.state = PgState::Down;
  c.in_len = 0;
  c.out.reset();
  if (!c.reconnect_requested) {
    c.reconnect_requested = true;
    request_reconnect(L.id, c.index);
  }
}

void on_pg_recv(Loop& L, std::uint32_t idx, std::uint32_t gen, int res) {
  PgConn& c = *L.pg[idx];
  if (c.gen != gen) return;
  c.recv_inflight = false;
  if (c.state != PgState::Up) {
    pg_maybe_finish_close(L, c);
    return;
  }
  if (res <= 0) {
    if (res == -EINTR || res == -EAGAIN) {
      pg_arm_recv(L, c);
      return;
    }
    util::log("loop %d: postgres connection %d lost (%s)", L.id, idx, res == 0 ? "closed" : std::strerror(-res));
    pg_conn_lost(L, c);
    pg_maybe_finish_close(L, c);
    return;
  }
  c.in_len += std::size_t(res);
  pg_process_input(L, c);
  if (c.state == PgState::Up) pg_arm_recv(L, c);
  else pg_maybe_finish_close(L, c);
}

void on_pg_send(Loop& L, std::uint32_t idx, std::uint32_t gen, int res) {
  PgConn& c = *L.pg[idx];
  if (c.gen != gen) return;
  c.out.inflight_end = 0;
  std::free(c.out.retired);
  c.out.retired = nullptr;
  if (c.state != PgState::Up) {
    pg_maybe_finish_close(L, c);
    return;
  }
  if (res < 0) {
    if (res == -EINTR || res == -EAGAIN) {
      pg_submit_send(L, c);
      return;
    }
    util::log("loop %d: postgres send failed on %d (%s)", L.id, idx, std::strerror(-res));
    pg_conn_lost(L, c);
    pg_maybe_finish_close(L, c);
    return;
  }
  c.out.sent += std::size_t(res);
  if (c.out.sent == c.out.len) {
    c.out.sent = c.out.len = 0;
  } else {
    pg_submit_send(L, c);
  }
}

// ---------- inbox and tick ----------

void drain_inbox(Loop& L) {
  {
    std::lock_guard<std::mutex> g(L.inbox_mu);
    L.inbox_swap.swap(L.inbox);
  }
  for (InboxMsg& m : L.inbox_swap) {
    if (m.kind == InboxMsg::BcryptDone) {
      on_bcrypt_done(L, m.req, m.ok);
    } else if (m.kind == InboxMsg::PgReady) {
      PgConn& c = *L.pg[m.pg_index];
      c.reconnect_requested = false;
      c.fd = m.pg_fd;
      c.gen = (c.gen + 1) & 0xFFFFFF;
      c.state = PgState::Up;
      c.in_len = 0;
      c.out.reset();
      c.g_head = c.g_count = 0;
      c.feed_inflight = 0;
      ++L.stats.pg_reconnects;
      util::log("loop %d: postgres connection %d %s", L.id, m.pg_index, "reconnected");
      pg_arm_recv(L, c);
    }
  }
  L.inbox_swap.clear();
}

void on_tick(Loop& L) {
  L.now_s = util::now_realtime_s();
  // Partial requests older than the deadline are dropped.
  if (L.partial_conns) {
    std::uint32_t deadline = std::uint32_t(L.now_s) - std::uint32_t(cfg::kPartialRequestTimeoutS);
    for (std::uint32_t s = 0; s < L.conn_hwm; ++s) {
      ClientConn& c = L.conns[s];
      if (c.state == kConnOpen && !c.active && c.first_byte_s && c.first_byte_s < deadline) close_conn(L, s);
    }
  }
  if (cfg::kStatsEnabled) {
    static thread_local std::int64_t last = 0;
    if (L.now_s - last >= cfg::kStatsIntervalS) {
      last = L.now_s;
      const Stats& s = L.stats;
      util::log("loop %d: conns=%u live_req=%u req=%llu 5xx=%llu groups=%llu batched=%llu wgroups=%llu wreqs=%llu "
                "retries=%llu shared=%llu bp=%llu grows=%llu hist=[%llu %llu %llu %llu %llu %llu %llu %llu]",
                L.id, L.open_conns, L.req_live, (unsigned long long)s.requests, (unsigned long long)s.responses_5xx,
                (unsigned long long)s.pg_groups, (unsigned long long)s.batched_reqs,
                (unsigned long long)s.write_groups, (unsigned long long)s.write_reqs,
                (unsigned long long)s.write_retries, (unsigned long long)s.shared_batches,
                (unsigned long long)s.backpressure,
                (unsigned long long)s.json_grows, (unsigned long long)s.batch_hist[0],
                (unsigned long long)s.batch_hist[1], (unsigned long long)s.batch_hist[2],
                (unsigned long long)s.batch_hist[3], (unsigned long long)s.batch_hist[4],
                (unsigned long long)s.batch_hist[5], (unsigned long long)s.batch_hist[6],
                (unsigned long long)s.batch_hist[7]);
    }
  }
}

void handle_cqe(Loop& L, io_uring_cqe* cqe) {
  std::uint64_t ud = io_uring_cqe_get_data64(cqe);
  switch (ud_op(ud)) {
    case kOpAccept: on_accept(L, cqe); break;
    case kOpPoll: on_poll(L, ud_idx(ud), ud_gen(ud), cqe); break;
    case kOpSend: on_send(L, ud_idx(ud), ud_gen(ud), cqe->res); break;
    case kOpPgRecv: on_pg_recv(L, ud_idx(ud), ud_gen(ud), cqe->res); break;
    case kOpPgSend: on_pg_send(L, ud_idx(ud), ud_gen(ud), cqe->res); break;
    case kOpEventfd:
      drain_inbox(L);
      arm_eventfd(L);
      break;
    case kOpTick:
      on_tick(L);
      arm_tick(L);
      break;
    case kOpAcceptRetry: arm_accept(L); break;
    default: break;
  }
}

int open_listener(const char* host, int port) {
  addrinfo hints{}, *res = nullptr;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;
  char portstr[16];
  std::snprintf(portstr, sizeof portstr, "%d", port);
  if (int rc = getaddrinfo(host, portstr, &hints, &res); rc != 0) util::die("getaddrinfo(%s): %s", host, gai_strerror(rc));
  int fd = ::socket(res->ai_family, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) util::die("socket: %s", std::strerror(errno));
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) != 0) util::die("SO_REUSEPORT: %s", std::strerror(errno));
  if (::bind(fd, res->ai_addr, res->ai_addrlen) != 0) util::die("bind %s:%d: %s", host, port, std::strerror(errno));
  freeaddrinfo(res);
  if (::listen(fd, cfg::kListenBacklog) != 0) util::die("listen: %s", std::strerror(errno));
  return fd;
}

}  // namespace

// ---------- shared helpers ----------

io_uring_sqe* get_sqe(Loop& L) {
  io_uring_sqe* sqe = io_uring_get_sqe(&L.ring);
  while (UNLIKELY(!sqe)) {
    io_uring_submit(&L.ring);
    sqe = io_uring_get_sqe(&L.ring);
  }
  return sqe;
}

Request* request_alloc(Loop& L) {
  if (UNLIKELY(L.req_live >= kMaxLiveRequests)) {
    L.paused = true;
    ++L.stats.backpressure;
    return nullptr;
  }
  Request* r;
  if (!L.req_free.empty()) {
    r = L.req_free.back();
    L.req_free.pop_back();
  } else {
    r = new (std::nothrow) Request();
    if (!r) return nullptr;
  }
  ++L.req_live;
  ++L.stats.requests;
  return r;
}

void request_free(Loop& L, Request* r) {
  L.stats.json_grows += r->out.grows;
  buf_free(L.pool, r->in);
  r->out.release();
  std::free(r->tags);
  *r = Request();
  --L.req_live;
  L.req_free.push_back(r);
  if (UNLIKELY(L.paused) && L.req_live < kMaxLiveRequests / 2) {
    L.paused = false;
    resume_paused(L);
  }
}

void respond(Loop& L, Request* r) {
  if (UNLIKELY(r->out.failed)) {
    respond_error(L, r, 500, "internal error");
    return;
  }
  ClientConn& c = L.conns[r->slot];
  if (r->status >= 500) ++L.stats.responses_5xx;
  if (r->out.buf.empty()) {  // 204: header only
    if (!r->out.begin(L.pool, 0)) {
      // No memory for even a header: drop the connection.
      std::uint32_t slot = r->slot;
      c.active = nullptr;
      request_free(L, r);
      close_conn(L, slot);
      return;
    }
  }
  bool close = !r->keep_alive || (c.flags & kCloseAfter);
  char* hdr = http::write_headers_before(r->out.body(), r->out.body_len(), r->status, close);
  r->send_start = std::uint32_t(hdr - r->out.buf.p);
  c.send_off = 0;
  if (c.state != kConnOpen) {  // connection already gone: nothing to send
    c.active = nullptr;
    request_free(L, r);
    return;
  }
  start_send(L, r->slot);
}

void respond_error(Loop& L, Request* r, int status, std::string_view msg) {
  r->out.release();
  r->status = std::int16_t(status);
  if (r->out.begin(L.pool, 64 + msg.size())) {
    r->out.lit("{\"errors\":{\"body\":[");
    r->out.str(msg);
    r->out.lit("]}}");
  }
  if (r->out.failed) {
    ClientConn& c = L.conns[r->slot];
    c.active = nullptr;
    std::uint32_t slot = r->slot;
    request_free(L, r);
    close_conn(L, slot);
    return;
  }
  respond(L, r);
}

void pg_submit_send(Loop& L, PgConn& c) {
  if (c.out.inflight_end || c.out.pending() == 0 || c.state != PgState::Up) return;
  io_uring_sqe* sqe = get_sqe(L);
  io_uring_prep_send(sqe, c.fd, c.out.data + c.out.sent, c.out.pending(), MSG_NOSIGNAL);
  io_uring_sqe_set_data64(sqe, make_ud(kOpPgSend, c.gen, c.index));
  c.out.inflight_end = c.out.len;
}

void post_to_loop(int loop_id, const InboxMsg& m) {
  Loop& L = *g_loops[std::size_t(loop_id)];
  {
    std::lock_guard<std::mutex> g(L.inbox_mu);
    L.inbox.push_back(m);
  }
  std::uint64_t one = 1;
  ssize_t w = ::write(L.event_fd, &one, sizeof one);
  (void)w;
}

SyncGroup* group_alloc(Loop& L) {
  SyncGroup* g = L.group_free;
  if (g) {
    L.group_free = g->next_free;
  } else {
    g = new SyncGroup();
  }
  g->n_entries = 0;
  g->cur = 0;
  g->n_reqs = 0;
  g->is_write = false;
  g->failed = false;
  g->fail_entry = 0;
  g->sqlstate[0] = 0;
  g->kind = 0;
  return g;
}

void group_free(Loop& L, SyncGroup* g) {
  g->next_free = L.group_free;
  L.group_free = g;
}

// ---------- setup and run ----------

bool loop_init(Loop& L, int id, const char* host, int port) {
  L.id = id;
  L.now_s = util::now_realtime_s();
  io_uring_params p{};
  p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_COOP_TASKRUN | IORING_SETUP_CQSIZE;
  p.cq_entries = cfg::kCqEntries;
  int rc = io_uring_queue_init_params(cfg::kSqEntries, &L.ring, &p);
  if (rc < 0) {
    util::log("loop %d: io_uring flags not supported (%s); falling back to CQSIZE only", id, std::strerror(-rc));
    p = io_uring_params{};
    p.flags = IORING_SETUP_CQSIZE;
    p.cq_entries = cfg::kCqEntries;
    rc = io_uring_queue_init_params(cfg::kSqEntries, &L.ring, &p);
    if (rc < 0) util::die("io_uring_queue_init: %s", std::strerror(-rc));
  }
  L.listen_fd = open_listener(host, port);
  L.event_fd = eventfd(0, EFD_CLOEXEC);
  if (L.event_fd < 0) util::die("eventfd: %s", std::strerror(errno));
  L.scratch = static_cast<char*>(std::aligned_alloc(64, cfg::kRecvScratchBytes));
  L.conn_cap = cfg::kMaxConnsPerLoop;
  void* m = mmap(nullptr, sizeof(ClientConn) * L.conn_cap, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (m == MAP_FAILED) util::die("mmap connection table: %s", std::strerror(errno));
  L.conns = static_cast<ClientConn*>(m);
  L.req_free.reserve(4096);
  return true;
}

void loop_add_pg(Loop& L, int fd, bool is_write) {
  PgConn* c = new PgConn();
  c->index = std::uint8_t(L.pg.size());
  c->is_write = is_write;
  c->fd = fd;
  c->state = PgState::Up;
  L.pg.push_back(c);
  if (is_write) ++L.n_write;
  else ++L.n_read;
}

void loop_run(Loop& L) {
  for (PgConn* c : L.pg) pg_arm_recv(L, *c);
  arm_accept(L);
  arm_eventfd(L);
  arm_tick(L);
  while (L.running) {
    int rc = io_uring_submit_and_wait(&L.ring, 1);
    if (rc < 0 && rc != -EINTR && rc != -ETIME && rc != -EBUSY && rc != -EAGAIN)
      util::die("loop %d: io_uring_submit_and_wait: %s", L.id, std::strerror(-rc));
    unsigned head, n = 0;
    io_uring_cqe* cqe;
    io_uring_for_each_cqe(&L.ring, head, cqe) {
      handle_cqe(L, cqe);
      if (++n == unsigned(cfg::kCqeBurst)) break;
    }
    io_uring_cq_advance(&L.ring, n);
    // Dispatch after draining, so requests that arrived together can share a batch.
    dispatch(L);
  }
}
