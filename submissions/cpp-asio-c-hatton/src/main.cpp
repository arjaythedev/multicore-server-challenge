// Conduit (RealWorld) API server for the multicore server challenge: C++20, Boost.Asio, libpq pipeline mode.
//
// Thread per core: every worker thread owns an io_context, its own SO_REUSEPORT listener (the kernel spreads
// connections over the workers) and its own Postgres connections. A connection never leaves its worker, so
// nothing on the request path takes a lock. bcrypt runs on a separate pool so it never stalls an event loop.
#include <crypt.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

#include <boost/asio.hpp>
#include <boost/json/src.hpp>  // Boost.JSON, header-only: compiled into this translation unit
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "bcrypt.hpp"
#include "jwt.hpp"
#include "pg.hpp"
#include "sql.hpp"
#include "util.hpp"

namespace json = boost::json;
using tcp = asio::ip::tcp;
using std::string;
using std::string_view;

static std::unique_ptr<Jwt> g_jwt;

// ---------- bcrypt pool ----------

// Hashes and verifies on a few dedicated threads. Jobs are gathered into batches of up to 4 that run
// interleaved (bcrypt.hpp): the oldest queued job waits at most BCRYPT_BATCH_MS for company, so under load a
// login costs well under half the CPU of a lone bcrypt. Only one thread forms a batch at a time.
class BcryptPool {
 public:
  using Done = std::function<void(const string& result)>;  // the full hash string, or "" on failure

  BcryptPool(unsigned n, int batch_ms) : batch_wait_(std::chrono::milliseconds(batch_ms)) {
    for (unsigned i = 0; i < n; ++i) threads_.emplace_back([this] { run(); });
  }

  // Cost-10 hash of pw; "" if bcrypt can't hash it (over 72 bytes, which Go's bcrypt refuses too).
  void hash(const string& pw, Done done) {
    char salt[CRYPT_GENSALT_OUTPUT_SIZE];
    if (pw.size() > 72 || !crypt_gensalt_rn("$2b$", 10, nullptr, 0, salt, sizeof salt)) return done("");
    submit(pw, salt, std::move(done));
  }
  // Recomputes the hash of pw with the stored hash's salt and cost; the caller compares.
  void rehash(const string& pw, const string& stored, Done done) { submit(pw, stored, std::move(done)); }

 private:
  struct Task {
    bcrypt::Job job;
    bool fast = false;
    string password, setting;
    Done done;
    std::chrono::steady_clock::time_point enq;
  };

  void submit(const string& pw, const string& setting, Done done) {
    auto t = std::make_unique<Task>();
    t->fast = bcrypt::prepare(t->job, pw, setting);
    if (!t->fast) {
      t->password = pw;
      t->setting = setting;
    }
    t->done = std::move(done);
    t->enq = std::chrono::steady_clock::now();
    {
      std::lock_guard<std::mutex> l(m_);
      q_.push_back(std::move(t));
    }
    cv_.notify_all();
  }

  void run() {
    std::vector<std::unique_ptr<Task>> batch;
    for (;;) {
      batch.clear();
      {
        std::unique_lock<std::mutex> l(m_);
        cv_.wait(l, [this] { return !q_.empty() && !forming_; });
        forming_ = true;
        if (q_.front()->fast) {
          auto deadline = q_.front()->enq + batch_wait_;
          cv_.wait_until(l, deadline, [this] { return count_fast_same_cost() >= 4; });
          int cost = q_.front()->job.cost;
          for (auto it = q_.begin(); it != q_.end() && batch.size() < 4;) {
            if ((*it)->fast && (*it)->job.cost == cost) {
              batch.push_back(std::move(*it));
              it = q_.erase(it);
            } else {
              ++it;
            }
          }
        } else {
          batch.push_back(std::move(q_.front()));
          q_.pop_front();
        }
        forming_ = false;
      }
      cv_.notify_all();
      if (batch[0]->fast) {
        bcrypt::Job* jobs[4];
        for (size_t i = 0; i < batch.size(); ++i) jobs[i] = &batch[i]->job;
        bcrypt::compute(jobs, int(batch.size()));
        for (auto& t : batch) t->done(t->job.result);
      } else {
        struct crypt_data d;
        d.initialized = 0;
        char* h = crypt_rn(batch[0]->password.c_str(), batch[0]->setting.c_str(), &d, sizeof d);
        batch[0]->done(h && h[0] != '*' ? string(h) : string());
      }
    }
  }

  size_t count_fast_same_cost() const {
    size_t n = 0;
    int cost = q_.front()->job.cost;
    for (auto& t : q_) n += t->fast && t->job.cost == cost;
    return n;
  }

  std::chrono::steady_clock::duration batch_wait_;
  std::mutex m_;
  std::condition_variable cv_;
  std::deque<std::unique_ptr<Task>> q_;
  bool forming_ = false;
  std::vector<std::thread> threads_;
};
static BcryptPool* g_bcrypt;

// ---------- worker / connection ----------

struct Worker {
  asio::io_context io{1};
  tcp::acceptor acc{io};
  PgPool rd, wr;  // reads; writes (commits wait on the WAL flush, so they don't queue behind reads and vice versa)
};

enum Method { M_GET, M_POST, M_PUT, M_DELETE, M_OTHER };

struct Conn {
  Worker* w;
  tcp::socket sock;
  string in;          // received, unprocessed bytes; the current request's views point into it
  size_t req_len = 0; // bytes of the current request (headers + body)
  string out;         // unsent response bytes (only after a short write)
  size_t out_off = 0;
  bool keep_alive = true;
  bool sent_continue = false;  // "100 Continue" already sent for the current request
  string chunked_body;         // a decoded chunked request body (c->body points into it)

  // current request
  Method method = M_OTHER;
  string_view path, query, body, auth;
  bool auth_present = false;
  int64_t viewer = 0;
  string token;
  string seg[6];  // decoded path segments after "/api/"
  int nseg = 0;

  // per-handler scratch, kept across async steps
  string s[6];
  bool has[6] = {};
  int64_t n1 = 0;

  Conn(Worker* w_, tcp::socket s_) : w(w_), sock(std::move(s_)) {}
};

static thread_local string tl_body;  // response body under construction (handlers run on their worker thread)
static thread_local char tl_rbuf[65536];

static void start_read(Conn* c);
static void try_process(Conn* c);
static void dispatch(Conn* c);

static void close_conn(Conn* c) {
  boost::system::error_code ec;
  c->sock.close(ec);
  delete c;
}

static const char* status_line(int st) {
  switch (st) {
    case 200: return "HTTP/1.1 200 OK\r\n";
    case 201: return "HTTP/1.1 201 Created\r\n";
    case 204: return "HTTP/1.1 204 No Content\r\n";
    case 400: return "HTTP/1.1 400 Bad Request\r\n";
    case 401: return "HTTP/1.1 401 Unauthorized\r\n";
    case 403: return "HTTP/1.1 403 Forbidden\r\n";
    case 404: return "HTTP/1.1 404 Not Found\r\n";
    case 413: return "HTTP/1.1 413 Content Too Large\r\n";
    case 422: return "HTTP/1.1 422 Unprocessable Entity\r\n";
    default: return "HTTP/1.1 500 Internal Server Error\r\n";
  }
}

static void after_response(Conn* c) {
  if (!c->keep_alive) return close_conn(c);
  c->in.erase(0, c->req_len);
  c->req_len = 0;
  if (c->in.empty()) {
    if (c->in.capacity() > 4096) string().swap(c->in);  // idle connections hold no buffer
    start_read(c);
  } else {
    try_process(c);
  }
}

static void write_rest(Conn* c) {
  c->sock.async_wait(tcp::socket::wait_write, [c](boost::system::error_code ec) {
    if (ec) return close_conn(c);
    while (c->out_off < c->out.size()) {
      ssize_t n = ::send(c->sock.native_handle(), c->out.data() + c->out_off, c->out.size() - c->out_off, MSG_NOSIGNAL);
      if (n > 0) {
        c->out_off += size_t(n);
      } else if (n < 0 && errno == EINTR) {
        continue;
      } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return write_rest(c);
      } else {
        return close_conn(c);
      }
    }
    string().swap(c->out);
    c->out_off = 0;
    after_response(c);
  });
}

// Sends status + body (JSON; empty for 204) and continues with the connection.
static void respond(Conn* c, int st, string_view body) {
  char hdr[160];
  int hl;
  const char* sl = status_line(st);
  const char* conn = c->keep_alive ? "" : "Connection: close\r\n";
  if (st == 204) {
    hl = std::snprintf(hdr, sizeof hdr, "%s%s\r\n", sl, conn);
    body = {};
  } else {
    hl = std::snprintf(hdr, sizeof hdr, "%sContent-Type: application/json\r\nContent-Length: %zu\r\n%s\r\n", sl,
                       body.size(), conn);
  }
  iovec iov[2] = {{hdr, size_t(hl)}, {const_cast<char*>(body.data()), body.size()}};
  msghdr mh{};
  mh.msg_iov = iov;
  mh.msg_iovlen = body.empty() ? 1 : 2;
  size_t total = size_t(hl) + body.size();
  ssize_t n;
  do n = ::sendmsg(c->sock.native_handle(), &mh, MSG_NOSIGNAL);
  while (n < 0 && errno == EINTR);
  if (n == ssize_t(total)) return after_response(c);
  if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) return close_conn(c);
  size_t sent = n < 0 ? 0 : size_t(n);
  c->out.clear();
  if (sent < size_t(hl)) c->out.append(hdr + sent, size_t(hl) - sent);
  size_t bo = sent > size_t(hl) ? sent - size_t(hl) : 0;
  c->out.append(body.data() + bo, body.size() - bo);
  c->out_off = 0;
  write_rest(c);
}

static void respond_error(Conn* c, int st, const char* msg) {
  string& o = tl_body;
  o.clear();
  o += "{\"errors\":{\"body\":[";
  json_str(o, msg);
  o += "]}}";
  respond(c, st, o);
}

static void start_read(Conn* c) {
  c->sock.async_wait(tcp::socket::wait_read, [c](boost::system::error_code ec) {
    if (ec) return close_conn(c);
    for (;;) {
      ssize_t n = ::recv(c->sock.native_handle(), tl_rbuf, sizeof tl_rbuf, 0);
      if (n > 0) {
        c->in.append(tl_rbuf, size_t(n));
        if (size_t(n) < sizeof tl_rbuf) break;
      } else if (n == 0) {
        return close_conn(c);
      } else if (errno == EINTR) {
        continue;
      } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
        break;
      } else {
        return close_conn(c);
      }
    }
    try_process(c);
  });
}

static bool ieq(string_view a, string_view b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i)
    if ((a[i] | 0x20) != (b[i] | 0x20)) return false;
  return true;
}

static string_view trim(string_view s) {
  while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) s.remove_prefix(1);
  while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) s.remove_suffix(1);
  return s;
}

static constexpr size_t kMaxHeader = 64 * 1024, kMaxBody = 4 * 1024 * 1024;

// Parses one request from c->in. 1 = complete, 0 = need more bytes, -1 = malformed, -2 = too large,
// -3 = need the body and the client expects "100 Continue" first.
static int parse_request(Conn* c) {
  string_view in(c->in);
  size_t he = in.find("\r\n\r\n");
  if (he == string_view::npos) return in.size() > kMaxHeader ? -2 : 0;
  string_view head = in.substr(0, he);
  size_t le = head.find("\r\n");
  string_view line = head.substr(0, le);
  size_t sp1 = line.find(' ');
  if (sp1 == string_view::npos) return -1;
  size_t sp2 = line.find(' ', sp1 + 1);
  if (sp2 == string_view::npos) return -1;
  string_view m = line.substr(0, sp1), target = line.substr(sp1 + 1, sp2 - sp1 - 1), ver = line.substr(sp2 + 1);
  if (m == "GET") c->method = M_GET;
  else if (m == "POST") c->method = M_POST;
  else if (m == "PUT") c->method = M_PUT;
  else if (m == "DELETE") c->method = M_DELETE;
  else c->method = M_OTHER;
  bool http10 = ver == "HTTP/1.0";
  if (!http10 && ver != "HTTP/1.1") return -1;
  c->keep_alive = !http10;
  size_t q = target.find('?');
  c->path = target.substr(0, q);
  c->query = q == string_view::npos ? string_view() : target.substr(q + 1);
  c->auth = {};
  c->auth_present = false;
  size_t clen = 0;
  bool chunked = false, expect_continue = false;
  size_t pos = le == string_view::npos ? head.size() : le + 2;
  while (pos < head.size()) {
    size_t e = head.find("\r\n", pos);
    if (e == string_view::npos) e = head.size();
    string_view h = head.substr(pos, e - pos);
    pos = e + 2;
    size_t colon = h.find(':');
    if (colon == string_view::npos) continue;
    string_view name = h.substr(0, colon), val = trim(h.substr(colon + 1));
    switch (name.size()) {
      case 14:
        if (ieq(name, "content-length")) {
          int64_t v;
          if (!parse_uint(val, v)) return -1;
          clen = size_t(v);
        }
        break;
      case 13:
        if (ieq(name, "authorization") && !c->auth_present) {
          c->auth = val;
          c->auth_present = true;
        }
        break;
      case 10:
        if (ieq(name, "connection")) {
          if (ieq(val, "close")) c->keep_alive = false;
          else if (ieq(val, "keep-alive")) c->keep_alive = true;
        }
        break;
      case 17:
        if (ieq(name, "transfer-encoding")) {
          if (!ieq(val, "chunked")) return -1;
          chunked = true;
        }
        break;
      case 6:
        if (ieq(name, "expect") && ieq(val, "100-continue")) expect_continue = true;
        break;
    }
  }
  size_t bstart = he + 4;
  if (chunked) {
    // decode the whole body before handling the request
    string& b = c->chunked_body;
    b.clear();
    size_t p = bstart;
    for (;;) {
      size_t eol = in.find("\r\n", p);
      if (eol == string_view::npos) return in.size() - bstart > kMaxBody ? -2 : (expect_continue ? -3 : 0);
      string_view sz = in.substr(p, eol - p);
      sz = sz.substr(0, sz.find(';'));  // chunk extensions
      size_t n = 0;
      if (sz.empty() || sz.size() > 8) return -1;
      for (char ch : sz) {
        int v = hexval(ch);
        if (v < 0) return -1;
        n = n * 16 + size_t(v);
      }
      if (b.size() + n > kMaxBody) return -2;
      if (n == 0) {
        // trailer section: lines up to an empty line
        size_t t = eol + 2;
        for (;;) {
          size_t te = in.find("\r\n", t);
          if (te == string_view::npos) return 0;
          if (te == t) {
            c->req_len = te + 2;
            c->body = b;
            return 1;
          }
          t = te + 2;
        }
      }
      if (in.size() < eol + 2 + n + 2) return expect_continue ? -3 : 0;
      b.append(in.data() + eol + 2, n);
      p = eol + 2 + n + 2;
    }
  }
  if (clen > kMaxBody) return -2;
  size_t total = bstart + clen;
  if (in.size() < total) return expect_continue && in.size() == bstart ? -3 : 0;
  c->body = in.substr(bstart, clen);
  c->req_len = total;
  return 1;
}

static void try_process(Conn* c) {
  int r = parse_request(c);
  if (r == -3) {  // the client waits for "100 Continue" before sending the body
    if (!c->sent_continue) {
      c->sent_continue = true;
      static const char cont[] = "HTTP/1.1 100 Continue\r\n\r\n";
      ::send(c->sock.native_handle(), cont, sizeof cont - 1, MSG_NOSIGNAL);
    }
    return start_read(c);
  }
  if (r == 0) return start_read(c);
  c->sent_continue = false;
  if (r < 0) {
    c->keep_alive = false;
    c->req_len = c->in.size();
    return respond_error(c, r == -2 ? 413 : 400, "bad request");
  }
  dispatch(c);
}

// ---------- request helpers ----------

// Query parameter lookup with Go's url.Query() semantics: first occurrence, '+' is a space.
static bool query_param(Conn* c, string_view key, string& out) {
  string_view q = c->query;
  string k;
  while (!q.empty()) {
    size_t amp = q.find('&');
    string_view pair = q.substr(0, amp);
    q = amp == string_view::npos ? string_view() : q.substr(amp + 1);
    if (pair.empty()) continue;
    size_t eq = pair.find('=');
    string_view rk = pair.substr(0, eq), rv = eq == string_view::npos ? string_view() : pair.substr(eq + 1);
    if (!url_decode(rk, k, true)) continue;
    if (k != key) continue;
    if (!url_decode(rv, out, true)) continue;
    return true;
  }
  return false;
}

// limit (default 20, 1..100) and offset (default 0, >= 0); a parameter that is present must be valid.
static bool limit_offset(Conn* c, int64_t& limit, int64_t& offset) {
  string v;
  limit = 20;
  offset = 0;
  if (query_param(c, "limit", v)) {
    if (!parse_uint(v, limit) || limit < 1 || limit > 100) return false;
  }
  if (query_param(c, "offset", v)) {
    if (!parse_uint(v, offset)) return false;
  }
  return true;
}

// Authorization: "Token <jwt>". Sets viewer (0 if absent or invalid) and token.
static void authenticate(Conn* c) {
  c->viewer = 0;
  if (!c->auth_present) return;
  string_view a = c->auth;
  if (a.substr(0, 6) != "Token ") return;
  a.remove_prefix(6);
  c->viewer = g_jwt->verify(a);
  if (c->viewer) c->token.assign(a);
}

// Parses the body as {"<key>": {...}} and returns the inner object (Go reference's readWrapper).
static const json::object* read_wrapper(Conn* c, json::value& holder, const char* key) {
  boost::system::error_code ec;
  holder = json::parse(c->body, ec);
  if (ec || !holder.is_object()) return nullptr;
  auto* inner = holder.as_object().if_contains(key);
  if (!inner || !inner->is_object()) return nullptr;
  return &inner->as_object();
}

// Absent or null: ok, not present. A string: ok, present. Anything else (or "" with non_empty): error.
static bool opt_string(const json::object& o, const char* k, bool non_empty, string& out, bool& present) {
  present = false;
  auto* v = o.if_contains(k);
  if (!v || v->is_null()) return true;
  if (!v->is_string()) return false;
  if (non_empty && v->as_string().empty()) return false;
  out.assign(v->as_string().data(), v->as_string().size());
  present = true;
  return true;
}
static bool req_string(const json::object& o, const char* k, string& out) {
  bool present;
  return opt_string(o, k, true, out, present) && present;
}

// ---------- JSON output ----------

static void put_nullable(string& o, const Res& r, int row, int col) {
  if (r.null(row, col)) o += "null";
  else json_str(o, r.str(row, col));
}

static void put_tags(string& o, const Res& r, int row, int col) {
  o.push_back('[');
  const char* p = PQgetvalue(r.r, row, col);
  int32_t ndim = be32(p);
  if (ndim > 0) {
    int32_t n = be32(p + 12);
    p += 20;
    for (int32_t i = 0; i < n; ++i) {
      int32_t l = be32(p);
      p += 4;
      if (i) o.push_back(',');
      if (l < 0) {
        o += "null";
      } else {
        json_str(o, string_view(p, size_t(l)));
        p += l;
      }
    }
  }
  o.push_back(']');
}

// Article from the article_select() columns.
static void put_article(string& o, const Res& r, int row, bool full) {
  int k = full ? 1 : 0;
  o += "{\"slug\":";
  json_str(o, r.str(row, 1));
  o += ",\"title\":";
  json_str(o, r.str(row, 2));
  o += ",\"description\":";
  json_str(o, r.str(row, 3));
  if (full) {
    o += ",\"body\":";
    json_str(o, r.str(row, 4));
  }
  o += ",\"tagList\":";
  put_tags(o, r, row, 6 + k);
  o += ",\"createdAt\":";
  json_ts(o, r.i64(row, 4 + k));
  o += ",\"updatedAt\":";
  json_ts(o, r.i64(row, 5 + k));
  o += r.b(row, 8 + k) ? ",\"favorited\":true" : ",\"favorited\":false";
  o += ",\"favoritesCount\":";
  json_int(o, r.i64(row, 7 + k));
  o += ",\"author\":{\"username\":";
  json_str(o, r.str(row, 9 + k));
  o += ",\"bio\":";
  put_nullable(o, r, row, 10 + k);
  o += ",\"image\":";
  put_nullable(o, r, row, 11 + k);
  o += r.b(row, 12 + k) ? ",\"following\":true}}" : ",\"following\":false}}";
}

static void respond_article(Conn* c, int st, const Res& r) {
  string& o = tl_body;
  o.clear();
  o += "{\"article\":";
  put_article(o, r, 0, true);
  o += '}';
  respond(c, st, o);
}

// User from columns id, username, email, bio, image.
static void respond_user(Conn* c, int st, const Res& r, string_view token) {
  string& o = tl_body;
  o.clear();
  o += "{\"user\":{\"email\":";
  json_str(o, r.str(0, 2));
  o += ",\"token\":";
  json_str(o, token);
  o += ",\"username\":";
  json_str(o, r.str(0, 1));
  o += ",\"bio\":";
  put_nullable(o, r, 0, 3);
  o += ",\"image\":";
  put_nullable(o, r, 0, 4);
  o += "}}";
  respond(c, st, o);
}

// Profile from columns username, bio, image at col.
static void respond_profile(Conn* c, const Res& r, int col, bool following) {
  string& o = tl_body;
  o.clear();
  o += "{\"profile\":{\"username\":";
  json_str(o, r.str(0, col));
  o += ",\"bio\":";
  put_nullable(o, r, 0, col + 1);
  o += ",\"image\":";
  put_nullable(o, r, 0, col + 2);
  o += following ? ",\"following\":true}}" : ",\"following\":false}}";
  respond(c, 200, o);
}

static void internal_error(Conn* c) { respond_error(c, 500, "internal error"); }

// Runs a bcrypt operation and continues with its result on the connection's worker thread.
template <class Start, class F>
static void bcrypt_then(Conn* c, Start start, F then) {
  Worker* w = c->w;
  start([w, then = std::move(then)](const string& result) mutable {
    asio::post(w->io, [result, then = std::move(then)]() mutable { then(result); });
  });
}

// ---------- handlers ----------

static void h_tags(Conn* c) {
  c->w->rd.pick().exec({{S_TAGS, 0, nullptr}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    string& o = tl_body;
    o.clear();
    o += "{\"tags\":[";
    const Res& t = r[0];
    for (int i = 0, n = t.rows(); i < n; ++i) {
      if (i) o.push_back(',');
      json_str(o, t.str(i, 0));
    }
    o += "]}";
    respond(c, 200, o);
  });
}

static void h_register(Conn* c) {
  json::value v;
  auto* u = read_wrapper(c, v, "user");
  if (!u || !req_string(*u, "username", c->s[0]) || !req_string(*u, "email", c->s[1]) ||
      !req_string(*u, "password", c->s[2]))
    return respond_error(c, 422, "username, email and password are required");
  bcrypt_then(
      c, [c](BcryptPool::Done d) { g_bcrypt->hash(c->s[2], std::move(d)); },
      [c](const string& hash) {
        if (hash.empty()) return respond_error(c, 422, "password is too long");
        c->s[3] = hash;
        const char* p[3] = {c->s[0].c_str(), c->s[1].c_str(), c->s[3].c_str()};
        c->w->wr.pick().exec({{S_REGISTER, 3, p}}, [c](PgResults& r) {
          if (r.unique_violation()) return respond_error(c, 422, "username or email is already taken");
          if (!r.ok || r[0].rows() != 1) return internal_error(c);
          respond_user(c, 201, r[0], g_jwt->issue(r[0].i64(0, 0)));
        });
      });
}

static void h_login(Conn* c) {
  json::value v;
  auto* u = read_wrapper(c, v, "user");
  if (!u || !req_string(*u, "email", c->s[0]) || !req_string(*u, "password", c->s[1]))
    return respond_error(c, 422, "email and password are required");
  const char* p[1] = {c->s[0].c_str()};
  c->w->rd.pick().exec({{S_LOGIN, 1, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 401, "invalid email or password");
    // Keep the row's fields for after the bcrypt check (the result is freed when this callback returns).
    const Res& x = r[0];
    c->n1 = x.i64(0, 0);
    c->s[2].assign(x.str(0, 1));
    c->s[3].assign(x.str(0, 2));
    c->has[4] = !x.null(0, 3);
    c->s[4].assign(x.str(0, 3));
    c->has[5] = !x.null(0, 4);
    c->s[5].assign(x.str(0, 4));
    c->token.assign(x.str(0, 5));  // stored hash
    bcrypt_then(
        c, [c](BcryptPool::Done d) { g_bcrypt->rehash(c->s[1], c->token, std::move(d)); },
        [c](const string& h) {
          bool ok = !h.empty() && h.size() == c->token.size() && CRYPTO_memcmp(h.data(), c->token.data(), h.size()) == 0;
          if (!ok) return respond_error(c, 401, "invalid email or password");
          string& o = tl_body;
          o.clear();
          o += "{\"user\":{\"email\":";
          json_str(o, c->s[3]);
          o += ",\"token\":";
          json_str(o, g_jwt->issue(c->n1));
          o += ",\"username\":";
          json_str(o, c->s[2]);
          o += ",\"bio\":";
          if (c->has[4]) json_str(o, c->s[4]);
          else o += "null";
          o += ",\"image\":";
          if (c->has[5]) json_str(o, c->s[5]);
          else o += "null";
          o += "}}";
          respond(c, 200, o);
        });
  });
}

static void h_get_user(Conn* c) {
  char id[24];
  const char* p[1] = {fmt_int(id, c->viewer)};
  c->w->rd.pick().exec({{S_USER, 1, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 401, "unauthorized");
    respond_user(c, 200, r[0], c->token);
  });
}

static void update_user_exec(Conn* c) {
  char id[24];
  // s[0] email, s[1] username, s[2] password -> s[5] hash, s[3] bio, s[4] image
  const char* p[6] = {fmt_int(id, c->viewer), c->has[0] ? c->s[0].c_str() : nullptr,
                      c->has[1] ? c->s[1].c_str() : nullptr, c->has[2] ? c->s[5].c_str() : nullptr,
                      c->has[3] ? c->s[3].c_str() : nullptr, c->has[4] ? c->s[4].c_str() : nullptr};
  c->w->wr.pick().exec({{S_UPDATE_USER, 6, p}}, [c](PgResults& r) {
    if (r.unique_violation()) return respond_error(c, 422, "username or email is already taken");
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 401, "unauthorized");
    respond_user(c, 200, r[0], c->token);
  });
}

static void h_put_user(Conn* c) {
  json::value v;
  auto* u = read_wrapper(c, v, "user");
  if (!u) return respond_error(c, 422, "invalid body");
  if (!opt_string(*u, "email", true, c->s[0], c->has[0]) || !opt_string(*u, "username", true, c->s[1], c->has[1]) ||
      !opt_string(*u, "password", true, c->s[2], c->has[2]) || !opt_string(*u, "bio", false, c->s[3], c->has[3]) ||
      !opt_string(*u, "image", false, c->s[4], c->has[4]))
    return respond_error(c, 422, "invalid user fields");
  if (!c->has[2]) return update_user_exec(c);
  bcrypt_then(
      c, [c](BcryptPool::Done d) { g_bcrypt->hash(c->s[2], std::move(d)); },
      [c](const string& hash) {
        if (hash.empty()) return respond_error(c, 422, "password is too long");
        c->s[5] = hash;
        update_user_exec(c);
      });
}

static void h_profile(Conn* c) {
  char id[24];
  const char* p[2] = {fmt_int(id, c->viewer), c->seg[1].c_str()};
  c->w->rd.pick().exec({{S_PROFILE, 2, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 404, "profile not found");
    respond_profile(c, r[0], 1, r[0].b(0, 4));
  });
}

static void h_follow(Conn* c, bool follow) {
  char id[24];
  const char* p[2] = {fmt_int(id, c->viewer), c->seg[1].c_str()};
  c->w->wr.pick().exec({{follow ? S_FOLLOW : S_UNFOLLOW, 2, p}}, [c, follow](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 404, "profile not found");
    respond_profile(c, r[0], 0, follow);
  });
}

static void write_list(Conn* c, const Res* a, int64_t count) {
  string& o = tl_body;
  o.clear();
  o += "{\"articles\":[";
  for (int i = 0, n = a ? a->rows() : 0; i < n; ++i) {
    if (i) o.push_back(',');
    put_article(o, *a, i, false);
  }
  o += "],\"articlesCount\":";
  json_int(o, count);
  o += '}';
  respond(c, 200, o);
}

// A list page with its count in column 13; an empty page runs the count statement (with params p) instead.
static void list_then_count(Conn* c, int list, int nparams, const char* const* p, int count, int cparams) {
  c->w->rd.pick().exec({{list, nparams, p}}, [c, count, cparams](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() > 0) return write_list(c, &r[0], r[0].i64(0, 13));
    // c->s[0] holds the filter (or the viewer id for the feed) for the count statement
    const char* cp2[1] = {c->s[0].c_str()};
    c->w->rd.pick().exec({{count, cparams, cp2}}, [c](PgResults& r2) {
      if (!r2.ok) return internal_error(c);
      write_list(c, nullptr, r2[0].i64(0, 0));
    });
  });
}

static void h_list(Conn* c) {
  int64_t limit, offset;
  if (!limit_offset(c, limit, offset)) return respond_error(c, 422, "limit must be 1-100 and offset >= 0");
  char vb[24], lb[24], ob[24];
  const char* p[4] = {fmt_int(vb, c->viewer), fmt_int(lb, limit), fmt_int(ob, offset), nullptr};
  string& f = c->s[0];
  int list = S_LIST_ALL, count = S_COUNT_ALL;
  if (query_param(c, "tag", f) && !f.empty()) list = S_LIST_TAG, count = S_COUNT_TAG;
  else if (query_param(c, "author", f) && !f.empty()) list = S_LIST_AUTHOR, count = S_COUNT_AUTHOR;
  else if (query_param(c, "favorited", f) && !f.empty()) list = S_LIST_FAV, count = S_COUNT_FAV;
  constexpr int64_t kDeep = 200;
  if (list == S_LIST_ALL) return list_then_count(c, offset > kDeep ? S_LIST_ALL_DEEP : list, 3, p, count, 0);
  if (list == S_LIST_AUTHOR && offset > kDeep) list = S_LIST_AUTHOR_DEEP;
  p[3] = f.c_str();
  list_then_count(c, list, 4, p, count, 1);
}

static void h_feed(Conn* c) {
  int64_t limit, offset;
  if (!limit_offset(c, limit, offset)) return respond_error(c, 422, "limit must be 1-100 and offset >= 0");
  char vb[24], lb[24], ob[24];
  const char* p[3] = {fmt_int(vb, c->viewer), fmt_int(lb, limit), fmt_int(ob, offset)};
  c->s[0] = vb;
  list_then_count(c, S_FEED, 3, p, S_COUNT_FEED, 1);
}

static void h_article(Conn* c) {
  char id[24];
  const char* p[2] = {fmt_int(id, c->viewer), c->seg[1].c_str()};
  c->w->rd.pick().exec({{S_ARTICLE_SLUG, 2, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 404, "article not found");
    respond_article(c, 200, r[0]);
  });
}

static void h_create_article(Conn* c) {
  json::value v;
  auto* a = read_wrapper(c, v, "article");
  if (!a) return respond_error(c, 422, "invalid body");
  if (!req_string(*a, "title", c->s[0]) || !req_string(*a, "description", c->s[1]) || !req_string(*a, "body", c->s[2]))
    return respond_error(c, 422, "title, description and body are required");
  // tagList as a Postgres text[] literal
  string& tags = c->s[3];
  tags.clear();
  bool any = false;
  if (auto* tl = a->if_contains("tagList"); tl && !tl->is_null()) {
    if (!tl->is_array()) return respond_error(c, 422, "tagList must be an array of non-empty strings");
    tags.push_back('{');
    for (auto& it : tl->as_array()) {
      if (!it.is_string() || it.as_string().empty())
        return respond_error(c, 422, "tagList must be an array of non-empty strings");
      if (any) tags.push_back(',');
      any = true;
      tags.push_back('"');
      for (char ch : it.as_string()) {
        if (ch == '"' || ch == '\\') tags.push_back('\\');
        tags.push_back(ch);
      }
      tags.push_back('"');
    }
    tags.push_back('}');
  }
  char id[24];
  const char* p[4] = {fmt_int(id, c->viewer), c->s[0].c_str(), c->s[1].c_str(), c->s[2].c_str()};
  const char* tp[1] = {tags.c_str()};
  auto cb = [c](PgResults& r) {
    if (!r.ok || r[r.n - 1].rows() != 1) return internal_error(c);
    respond_article(c, 201, r[r.n - 1]);
  };
  // One Sync: the inserts and the read-back commit together, and the response waits for the commit.
  if (any) {
    Stmt s[4] = {{S_CREATE_ARTICLE, 4, p}, {S_CREATE_TAGS, 1, tp}, {S_CREATE_ARTICLE_TAGS, 1, tp}, {S_ARTICLE_CURR, 1, p}};
    c->w->wr.pick().exec(s, 4, cb);
  } else {
    Stmt s[2] = {{S_CREATE_ARTICLE, 4, p}, {S_ARTICLE_CURR, 1, p}};
    c->w->wr.pick().exec(s, 2, cb);
  }
}

static void h_update_article(Conn* c) {
  json::value v;
  auto* a = read_wrapper(c, v, "article");
  if (!a) return respond_error(c, 422, "invalid body");
  if (!opt_string(*a, "title", true, c->s[0], c->has[0]) || !opt_string(*a, "description", true, c->s[1], c->has[1]) ||
      !opt_string(*a, "body", true, c->s[2], c->has[2]))
    return respond_error(c, 422, "invalid article fields");
  const char* p[1] = {c->seg[1].c_str()};
  c->w->rd.pick().exec({{S_ARTICLE_OWNER, 1, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 404, "article not found");
    if (r[0].i64(0, 1) != c->viewer) return respond_error(c, 403, "not the author");
    char ib[24], vb[24];
    fmt_int(ib, r[0].i64(0, 0));
    const char* up[4] = {ib, c->has[0] ? c->s[0].c_str() : nullptr, c->has[1] ? c->s[1].c_str() : nullptr,
                         c->has[2] ? c->s[2].c_str() : nullptr};
    const char* sp[2] = {fmt_int(vb, c->viewer), ib};
    c->w->wr.pick().exec({{S_UPDATE_ARTICLE, 4, up}, {S_ARTICLE_ID, 2, sp}}, [c](PgResults& r2) {
      if (!r2.ok || r2[1].rows() != 1) return internal_error(c);
      respond_article(c, 200, r2[1]);
    });
  });
}

static void h_delete_article(Conn* c) {
  const char* p[1] = {c->seg[1].c_str()};
  c->w->rd.pick().exec({{S_ARTICLE_OWNER, 1, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 404, "article not found");
    if (r[0].i64(0, 1) != c->viewer) return respond_error(c, 403, "not the author");
    char ib[24];
    const char* dp[1] = {fmt_int(ib, r[0].i64(0, 0))};
    c->w->wr.pick().exec({{S_DELETE_ARTICLE, 1, dp}}, [c](PgResults& r2) {
      if (!r2.ok) return internal_error(c);
      respond(c, 204, {});
    });
  });
}

static void h_favorite(Conn* c, bool fav) {
  char id[24];
  const char* p[2] = {fmt_int(id, c->viewer), c->seg[1].c_str()};
  // The write and the read-back in one transaction; the read sees the write. No article row = 404.
  c->w->wr.pick().exec({{fav ? S_FAVORITE : S_UNFAVORITE, 2, p}, {S_ARTICLE_SLUG, 2, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[1].rows() != 1) return respond_error(c, 404, "article not found");
    respond_article(c, 200, r[1]);
  });
}

static void h_comments(Conn* c) {
  char id[24];
  const char* p[2] = {fmt_int(id, c->viewer), c->seg[1].c_str()};
  c->w->rd.pick().exec({{S_COMMENTS, 2, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    const Res& x = r[0];
    int n = x.rows();
    if (n == 0) return respond_error(c, 404, "article not found");
    string& o = tl_body;
    o.clear();
    o += "{\"comments\":[";
    for (int i = 0; i < n; ++i) {
      if (x.null(i, 1)) break;
      if (i) o.push_back(',');
      o += "{\"id\":";
      json_int(o, x.i64(i, 1));
      o += ",\"createdAt\":";
      json_ts(o, x.i64(i, 3));
      o += ",\"updatedAt\":";
      json_ts(o, x.i64(i, 4));
      o += ",\"body\":";
      json_str(o, x.str(i, 2));
      o += ",\"author\":{\"username\":";
      json_str(o, x.str(i, 5));
      o += ",\"bio\":";
      put_nullable(o, x, i, 6);
      o += ",\"image\":";
      put_nullable(o, x, i, 7);
      o += x.b(i, 8) ? ",\"following\":true}}" : ",\"following\":false}}";
    }
    o += "]}";
    respond(c, 200, o);
  });
}

static void h_create_comment(Conn* c) {
  json::value v;
  auto* cm = read_wrapper(c, v, "comment");
  if (!cm || !req_string(*cm, "body", c->s[0])) return respond_error(c, 422, "body is required");
  char id[24];
  const char* p[3] = {fmt_int(id, c->viewer), c->seg[1].c_str(), c->s[0].c_str()};
  c->w->wr.pick().exec({{S_CREATE_COMMENT, 3, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    const Res& x = r[0];
    if (x.rows() != 1) return respond_error(c, 404, "article not found");
    string& o = tl_body;
    o.clear();
    o += "{\"comment\":{\"id\":";
    json_int(o, x.i64(0, 0));
    o += ",\"createdAt\":";
    json_ts(o, x.i64(0, 2));
    o += ",\"updatedAt\":";
    json_ts(o, x.i64(0, 3));
    o += ",\"body\":";
    json_str(o, x.str(0, 1));
    o += ",\"author\":{\"username\":";
    json_str(o, x.str(0, 4));
    o += ",\"bio\":";
    put_nullable(o, x, 0, 5);
    o += ",\"image\":";
    put_nullable(o, x, 0, 6);
    o += ",\"following\":false}}}";
    respond(c, 201, o);
  });
}

static void h_delete_comment(Conn* c) {
  int64_t cid;
  if (!parse_uint(c->seg[3], cid)) return respond_error(c, 404, "comment not found");
  c->n1 = cid;
  char ib[24];
  const char* p[2] = {fmt_int(ib, cid), c->seg[1].c_str()};
  c->w->rd.pick().exec({{S_COMMENT_OWNER, 2, p}}, [c](PgResults& r) {
    if (!r.ok) return internal_error(c);
    if (r[0].rows() != 1) return respond_error(c, 404, "comment not found");
    if (r[0].i64(0, 0) != c->viewer) return respond_error(c, 403, "not the author");
    char ib2[24];
    const char* dp[1] = {fmt_int(ib2, c->n1)};
    c->w->wr.pick().exec({{S_DELETE_COMMENT, 1, dp}}, [c](PgResults& r2) {
      if (!r2.ok) return internal_error(c);
      respond(c, 204, {});
    });
  });
}

// ---------- routing ----------

enum AuthMode { A_NONE, A_OPTIONAL, A_REQUIRED };

static void dispatch(Conn* c) {
  // split "/api/..." into decoded segments
  string_view p = c->path;
  c->nseg = 0;
  if (p.substr(0, 5) != "/api/") return respond_error(c, 404, "not found");
  p.remove_prefix(5);
  for (;;) {
    size_t sl = p.find('/');
    string_view sv = p.substr(0, sl);
    if (c->nseg == 6 || !url_decode(sv, c->seg[c->nseg], false) || sv.empty())
      return respond_error(c, 404, "not found");
    ++c->nseg;
    if (sl == string_view::npos) break;
    p.remove_prefix(sl + 1);
  }
  const string* s = c->seg;
  int n = c->nseg;
  Method m = c->method;
  void (*h)(Conn*) = nullptr;
  AuthMode am = A_NONE;
  if (s[0] == "articles") {
    if (n == 1) {
      if (m == M_GET) h = h_list, am = A_OPTIONAL;
      else if (m == M_POST) h = h_create_article, am = A_REQUIRED;
    } else if (n == 2) {
      if (m == M_GET) {
        if (s[1] == "feed") h = h_feed, am = A_REQUIRED;
        else h = h_article, am = A_OPTIONAL;
      } else if (m == M_PUT) h = h_update_article, am = A_REQUIRED;
      else if (m == M_DELETE) h = h_delete_article, am = A_REQUIRED;
    } else if (n == 3 && s[2] == "comments") {
      if (m == M_GET) h = h_comments, am = A_OPTIONAL;
      else if (m == M_POST) h = h_create_comment, am = A_REQUIRED;
    } else if (n == 3 && s[2] == "favorite") {
      if (m == M_POST) h = [](Conn* c) { h_favorite(c, true); }, am = A_REQUIRED;
      else if (m == M_DELETE) h = [](Conn* c) { h_favorite(c, false); }, am = A_REQUIRED;
    } else if (n == 4 && s[2] == "comments" && m == M_DELETE) {
      h = h_delete_comment, am = A_REQUIRED;
    }
  } else if (s[0] == "tags") {
    if (n == 1 && m == M_GET) h = h_tags;
  } else if (s[0] == "user") {
    if (n == 1 && m == M_GET) h = h_get_user, am = A_REQUIRED;
    else if (n == 1 && m == M_PUT) h = h_put_user, am = A_REQUIRED;
  } else if (s[0] == "users") {
    if (n == 1 && m == M_POST) h = h_register;
    else if (n == 2 && s[1] == "login" && m == M_POST) h = h_login;
  } else if (s[0] == "profiles") {
    if (n == 2 && m == M_GET) h = h_profile, am = A_OPTIONAL;
    else if (n == 3 && s[2] == "follow") {
      if (m == M_POST) h = [](Conn* c) { h_follow(c, true); }, am = A_REQUIRED;
      else if (m == M_DELETE) h = [](Conn* c) { h_follow(c, false); }, am = A_REQUIRED;
    }
  }
  if (!h) return respond_error(c, 404, "not found");
  if (am != A_NONE) {
    authenticate(c);
    if (c->viewer == 0 && (am == A_REQUIRED || c->auth_present)) return respond_error(c, 401, "unauthorized");
  }
  h(c);
}

// ---------- startup ----------

static void do_accept(Worker* w) {
  w->acc.async_accept([w](boost::system::error_code ec, tcp::socket s) {
    if (!ec) {
      s.non_blocking(true);
      int one = 1;
      ::setsockopt(s.native_handle(), IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
      start_read(new Conn(w, std::move(s)));
    } else if (ec == asio::error::operation_aborted) {
      return;
    } else {
      // e.g. out of file descriptors: back off briefly instead of spinning
      auto t = std::make_shared<asio::steady_timer>(w->io, std::chrono::milliseconds(20));
      t->async_wait([w, t](boost::system::error_code) { do_accept(w); });
      return;
    }
    do_accept(w);
  });
}

static string env(const char* k, const char* def) {
  const char* v = std::getenv(k);
  return v && *v ? v : def;
}

int main() {
  std::signal(SIGPIPE, SIG_IGN);
  // Direct mode holds one socket per user: raise the soft fd limit to the hard limit.
  rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
    rl.rlim_cur = rl.rlim_max;
    setrlimit(RLIMIT_NOFILE, &rl);
  }
  string db = env("DATABASE_URL", ""), secret = env("JWT_SECRET", "");
  if (db.empty() || secret.empty()) {
    std::fprintf(stderr, "DATABASE_URL and JWT_SECRET are required\n");
    return 1;
  }
  string host = env("HOST", "127.0.0.1");
  int port = std::atoi(env("PORT", "3000").c_str());
  unsigned cores = std::max(1u, std::thread::hardware_concurrency());
  unsigned nthreads = unsigned(std::atoi(env("THREADS", std::to_string(cores).c_str()).c_str()));
  int rd_per = std::atoi(env("PG_READ_CONNS", "1").c_str());
  int wr_per = std::atoi(env("PG_WRITE_CONNS", "1").c_str());
  bool group_commit = env("GROUP_COMMIT", "1") != "0";
  unsigned bthreads = unsigned(std::atoi(env("BCRYPT_THREADS", std::to_string(std::max(2u, cores / 2)).c_str()).c_str()));
  int batch_ms = std::atoi(env("BCRYPT_BATCH_MS", "40").c_str());

  g_jwt = std::make_unique<Jwt>(secret);
  g_bcrypt = new BcryptPool(bthreads, batch_ms);

  std::vector<string> setup = {"SET jit = off", "SET plan_cache_mode = " + env("PLAN_CACHE_MODE", "force_generic_plan")};
  std::vector<string> sql = all_sql();
  auto ep = tcp::endpoint(asio::ip::make_address(host), static_cast<unsigned short>(port));

  std::vector<std::unique_ptr<Worker>> workers;
  for (unsigned i = 0; i < nthreads; ++i) {
    auto w = std::make_unique<Worker>();
    for (int k = 0; k < rd_per; ++k) w->rd.add(std::make_unique<PgConn>(w->io, db, sql, setup, false));
    for (int k = 0; k < wr_per; ++k) w->wr.add(std::make_unique<PgConn>(w->io, db, sql, setup, group_commit));
    w->acc.open(ep.protocol());
    w->acc.set_option(asio::socket_base::reuse_address(true));
    int one = 1;
    ::setsockopt(w->acc.native_handle(), SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    w->acc.bind(ep);
    w->acc.listen(65535);
    do_accept(w.get());
    workers.push_back(std::move(w));
  }
  std::fprintf(stderr, "conduit (c++/asio) on %s:%d: %u threads, %d+%d pg connections each, %u bcrypt threads\n",
               host.c_str(), port, nthreads, rd_per, wr_per, bthreads);
  std::vector<std::thread> threads;
  for (auto& w : workers) threads.emplace_back([w = w.get()] { w->io.run(); });
  for (auto& t : threads) t.join();
}
