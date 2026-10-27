// Core runtime types shared by the event loop, the scheduler and the endpoint handlers.
//
// Shared-nothing: each event-loop thread owns one io_uring, one SO_REUSEPORT listener, its client connections,
// its Postgres connections, its queues and its memory. A request stays on one thread from recv to send.
#pragma once
#include <liburing.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string_view>
#include <vector>

#include "config.hpp"
#include "http.hpp"
#include "json_write.hpp"
#include "pg.hpp"
#include "pool.hpp"
#include "sql.hpp"

struct Loop;

// ---- io_uring user_data: [op:8][gen:24][index:32] ----
enum Op : std::uint8_t {
  kOpAccept = 1,
  kOpPoll,
  kOpSend,
  kOpIgnore,   // completions we do not care about (poll_remove, cancel)
  kOpPgRecv,
  kOpPgSend,
  kOpEventfd,
  kOpTick,
  kOpAcceptRetry,
};
inline std::uint64_t make_ud(Op op, std::uint32_t gen, std::uint32_t idx) {
  return (std::uint64_t(op) << 56) | (std::uint64_t(gen & 0xFFFFFF) << 32) | idx;
}
inline Op ud_op(std::uint64_t ud) { return Op(ud >> 56); }
inline std::uint32_t ud_gen(std::uint64_t ud) { return std::uint32_t(ud >> 32) & 0xFFFFFF; }
inline std::uint32_t ud_idx(std::uint64_t ud) { return std::uint32_t(ud); }

enum class Route : std::uint8_t {
  None,
  Register,
  Login,
  GetUser,
  PutUser,
  GetProfile,
  Follow,
  Unfollow,
  ListArticles,
  Feed,
  GetArticle,
  CreateArticle,
  UpdateArticle,
  DeleteArticle,
  Favorite,
  Unfavorite,
  GetComments,
  CreateComment,
  DeleteComment,
  Tags,
  Count
};

// One HTTP request from parse to the end of its response send.
struct Request {
  Request* next = nullptr;        // intrusive queue link
  std::uint32_t slot = 0;         // owning client connection
  Route route = Route::None;
  std::uint8_t stage = 0;         // handler step
  std::uint8_t stmt = 0;          // statement of the current database step
  std::uint8_t flags = 0;         // handler-specific bits (e.g. "first statement returned a row")
  bool keep_alive = true;
  bool got_row = false;           // current statement returned at least one row
  bool retried = false;           // already retried alone after a transient failure
  std::int16_t status = 0;
  std::int64_t viewer = 0;
  std::int64_t limit = 0, offset = 0;
  std::int64_t num = 0;           // a numeric param or result (comment id, list count, ...)
  std::int64_t r_id = 0, r_author = 0;  // results carried between steps
  std::string_view token;         // the presented token (GET/PUT /api/user echo it)
  std::string_view s[6];          // string params; meaning depends on the route
  std::uint8_t s_null = 0;        // bit i set: s[i] is SQL NULL (absent / null in the body)
  std::string_view* tags = nullptr;  // POST /api/articles tagList (heap; rare path)
  int n_tags = 0;
  char hash[64];                  // bcrypt hash: stored (login) or new (register, password change)
  std::uint8_t hash_len = 0;
  Buf in;                         // copy of the raw request bytes; parsed views point into it
  JsonOut out;                    // response body
  std::uint32_t send_start = 0;   // offset of the first header byte in out.buf
  std::int64_t t_start_us = 0;    // for queue-wait stats
};

// A client TCP connection. Hot fields first; kept small because idle connections dominate.
struct ClientConn {
  std::int32_t fd = -1;
  std::uint32_t gen = 0;
  std::uint8_t state = 0;         // ConnState
  std::uint8_t flags = 0;         // ConnFlags
  std::uint16_t paused_events = 0;
  std::uint32_t carry_len = 0;    // bytes buffered (partial or pipelined requests)
  Buf carry;
  Request* active = nullptr;      // request being processed or sent
  std::uint32_t send_off = 0;     // bytes of the current response already sent
  std::uint32_t first_byte_s = 0; // when the buffered partial request started (coarse seconds)
  std::uint32_t next_free = 0;    // free-list link (slot + 1)
};
enum ConnState : std::uint8_t { kConnFree = 0, kConnOpen, kConnClosing };
enum ConnFlags : std::uint8_t {
  kPollArmed = 1,
  kReadPending = 2,     // the socket may hold unread bytes
  kCloseAfter = 4,      // close once the current response is sent
  kSending = 8,
  kPausedListed = 16,   // on the loop's ready-while-paused list
};

// ---- Postgres connection state inside a loop ----
// One Bind+Execute in a sync group; covers one request (single form) or several (batched form, rows carry the
// request ordinal in column 0).
struct StmtEntry {
  std::uint8_t stmt;
  std::uint8_t batched;   // 1: rows start with an int4 ordinal into reqs[first .. first+nreq)
  std::uint16_t nreq;
  std::uint32_t first;
};

inline constexpr int kMaxGroupEntries = cfg::kWriteBatchMax * 2 + 8;
inline constexpr int kMaxGroupReqs = cfg::kWriteBatchMax * 2 + 8;

struct SyncGroup {
  SyncGroup* next_free = nullptr;
  std::uint16_t n_entries = 0;
  std::uint16_t cur = 0;          // entry whose results are arriving
  std::uint32_t n_reqs = 0;
  bool is_write = false;
  bool failed = false;
  std::uint16_t fail_entry = 0;
  char sqlstate[6] = {};
  std::uint8_t kind = 0;          // scheduler read kind (for in-flight caps)
  StmtEntry entries[kMaxGroupEntries];
  Request* reqs[kMaxGroupReqs];
};

enum class PgState : std::uint8_t { Down, Up, Closing };

struct PgConn {
  int fd = -1;
  std::uint8_t index = 0;
  bool is_write = false;
  PgState state = PgState::Down;
  bool recv_inflight = false;
  bool reconnect_requested = false;
  std::uint32_t gen = 0;          // bumps on every new socket; stale CQEs are ignored
  pg::PgOut out;
  char* in = nullptr;
  std::size_t in_cap = 0, in_len = 0;
  SyncGroup* groups[8] = {};      // FIFO of in-flight sync groups
  std::uint8_t g_head = 0, g_count = 0;
  int feed_inflight = 0;
};

// Cross-thread messages into a loop (bcrypt completions, reconnected Postgres sockets). Low rate: a mutex is fine.
struct InboxMsg {
  enum Kind : std::uint8_t { BcryptDone, PgReady } kind;
  bool ok = false;
  Request* req = nullptr;
  int pg_index = -1;
  int pg_fd = -1;
};

struct Stats {
  std::uint64_t requests = 0, responses_5xx = 0, accepts = 0, closes = 0;
  std::uint64_t pg_groups = 0, pg_stmts = 0, batched_reqs = 0, write_groups = 0, write_reqs = 0, write_retries = 0;
  std::uint64_t backpressure = 0, json_grows = 0, pg_reconnects = 0, shared_batches = 0;
  std::uint64_t batch_hist[8] = {};  // batch size buckets: 1, 2, 3-4, 5-8, 9-16, 17-32, 33-64, 65+
};

struct Loop {
  int id = 0;
  io_uring ring{};
  int listen_fd = -1;
  int event_fd = -1;
  std::uint64_t event_buf = 0;
  __kernel_timespec tick_ts{};
  bool running = true;
  std::int64_t now_s = 0;         // coarse clock, refreshed every tick
  char* scratch = nullptr;        // receive scratch (cfg::kRecvScratchBytes)

  SlabPool pool;
  // client connections
  ClientConn* conns = nullptr;
  std::uint32_t conn_cap = 0, conn_hwm = 0;  // slots [0, conn_hwm) have been used
  std::uint32_t free_head = 0;               // free-list head + 1 (0 = empty)
  std::uint32_t open_conns = 0, partial_conns = 0;
  // backpressure
  bool paused = false;
  std::vector<std::uint64_t> paused_list;    // (gen << 32 | slot) of connections readable while paused, FIFO

  // requests and groups (pools with LIFO free lists)
  std::vector<Request*> req_free;
  std::uint32_t req_live = 0;
  SyncGroup* group_free = nullptr;

  // postgres
  std::vector<PgConn*> pg;        // read connections first, then write connections
  int n_read = 0, n_write = 0;

  // scheduler queues (see scheduler.cpp)
  struct Queue {
    Request* head = nullptr;
    Request* tail = nullptr;
    std::uint32_t len = 0;
  };
  Queue read_q[sql::kStmtCount];
  Queue write_q;
  Queue write_solo_q;             // statements that never share a transaction

  // inbox
  std::mutex inbox_mu;
  std::vector<InboxMsg> inbox, inbox_swap;

  Stats stats;
};

// ---- loop.cpp ----
io_uring_sqe* get_sqe(Loop& L);
void respond(Loop& L, Request* r);             // writes headers and starts sending r->out to its connection
void respond_error(Loop& L, Request* r, int status, std::string_view msg);
Request* request_alloc(Loop& L);
void request_free(Loop& L, Request* r);
void pg_submit_send(Loop& L, PgConn& c);
void post_to_loop(int loop_id, const InboxMsg& m);  // thread-safe
SyncGroup* group_alloc(Loop& L);
void group_free(Loop& L, SyncGroup* g);

// One statement parameter value (single and batched encoders share this description).
struct Param {
  enum Kind : std::uint8_t { Int8, Text, Null, TextArray } kind;
  std::int64_t i = 0;
  std::string_view s;
  const std::string_view* items = nullptr;  // TextArray
  int n_items = 0;
};

// ---- handlers.cpp ----
void handle_http(Loop& L, ClientConn& c, std::uint32_t slot, const http::Request& hr, const char* raw);
int params_of(const Request* r, std::uint8_t stmt, Param out[6]);
void encode_params(pg::Bind& b, Request* r, std::uint8_t stmt);
void on_row(Loop& L, Request* r, std::uint8_t stmt, pg::Row& row);
void on_stmt_done(Loop& L, Request* r, std::uint8_t stmt);
void on_read_done(Loop& L, Request* r, bool ok);
void on_write_group_done(Loop& L, SyncGroup& g);
void on_bcrypt_done(Loop& L, Request* r, bool ok);
int write_stmts(const Request* r, std::uint8_t out[2]);

// ---- scheduler.cpp ----
void enqueue_read(Loop& L, Request* r, std::uint8_t stmt);
void enqueue_write(Loop& L, Request* r, bool solo);
void dispatch(Loop& L);
void pg_conn_lost(Loop& L, PgConn& c);
void pg_process_input(Loop& L, PgConn& c);

// ---- bcrypt_pool.cpp ----
void bcrypt_pool_start();
// verify: r->s[1] password vs r->hash; hash: r->s[?] password -> r->hash. Completion via InboxMsg::BcryptDone.
void bcrypt_submit_verify(Loop& L, Request* r, std::string_view password);
void bcrypt_submit_hash(Loop& L, Request* r, std::string_view password);

// ---- main.cpp ----
extern std::vector<Loop*> g_loops;
extern pg::ConnInfo g_conninfo;
void request_reconnect(int loop_id, int pg_index);  // reconnect thread
