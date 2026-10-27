// Postgres wire protocol (v3) client pieces.
//
//  * connect_blocking(): TCP connect, StartupMessage with session options, SCRAM-SHA-256, prepare every statement
//    in sql.hpp. Used at startup and by the reconnect thread; returns a socket idle at ReadyForQuery.
//  * PgOut / Bind encoding: extended-protocol Bind + Execute + Sync, binary parameters and binary results.
//  * Message framing and binary value decoders used by the event loop when replies arrive.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>

#include "util.hpp"

namespace pg {

struct ConnInfo {
  std::string host = "127.0.0.1";
  std::string port = "5432";
  std::string user;
  std::string password;
  std::string dbname;
};

// Parses postgres://user:password@host:port/dbname[?...]. Returns false on malformed input.
bool parse_url(std::string_view url, ConnInfo& out);

// Opens a ready connection (statements prepared) or returns -1 and fills `err`.
int connect_blocking(const ConnInfo& ci, std::string& err);

// ---- outgoing buffer ----
// A linear byte buffer: bytes [sent, len) are waiting to go out. While a send is in flight the region
// [sent, inflight_end) belongs to the kernel and must not move; new bytes are appended after len.
struct PgOut {
  char* data = nullptr;
  std::size_t cap = 0;
  std::size_t len = 0;
  std::size_t sent = 0;
  std::size_t inflight_end = 0;  // 0 = no send in flight

  ~PgOut() {
    std::free(data);
    std::free(retired);
  }
  PgOut() = default;
  PgOut(const PgOut&) = delete;
  PgOut& operator=(const PgOut&) = delete;
  // Clears all state after a connection is lost (no send can be in flight then).
  void reset() {
    len = sent = inflight_end = 0;
    std::free(retired);
    retired = nullptr;
  }
  void reserve(std::size_t n) {
    if (len + n <= cap) return;
    // Reclaim the consumed prefix when no send is in flight; otherwise grow (realloc keeps contents, but an
    // in-flight send points into the old block, so never realloc while sending: allocate fresh and copy).
    if (inflight_end == 0 && sent > 0) {
      std::memmove(data, data + sent, len - sent);
      len -= sent;
      sent = 0;
      if (len + n <= cap) return;
    }
    std::size_t nc = cap ? cap : 64 * 1024;
    while (nc < len + n) nc *= 2;
    char* nd = static_cast<char*>(std::malloc(nc));
    if (!nd) util::die("out of memory (pg send buffer %zu)", nc);
    if (len) std::memcpy(nd, data, len);
    // An in-flight send still references the old block; keep it alive until the send completes.
    // Only the block current at submit time is referenced; a block from a second grow can go immediately.
    if (inflight_end != 0 && retired == nullptr) retired = data;
    else std::free(data);
    data = nd;
    cap = nc;
  }
  char* retired = nullptr;  // old block referenced by an in-flight send, freed when it completes
  std::size_t pending() const { return len - sent; }
};

// Bind (unnamed portal, named statement "s<id>") + Execute; all parameters and results in binary.
class Bind {
 public:
  // prefix 's' = single form, 'b' = batched form of the same statement id.
  Bind(PgOut& out, int stmt_id, int nparams, char prefix = 's');
  void int8(std::int64_t v);
  void int4(std::int32_t v);
  void text(std::string_view s);
  void null();
  // text[] from a list of views (no NULL elements)
  void text_array(const std::string_view* items, int n);
  // Raw parameter construction (array parameters): param_begin reserves the length field, param_end fills it.
  std::size_t param_begin();
  void param_end(std::size_t at);
  void append(const void* p, std::size_t n);
  void append_be32(std::uint32_t v);
  void append_be64(std::uint64_t v);
  void finish();  // writes result formats, closes Bind, appends Execute

 private:
  PgOut& out_;
  std::size_t start_;
  int nparams_, written_ = 0;
};
void sync(PgOut& out);

// ---- incoming messages ----
// Returns the full length of the message at p (type byte + int32 length) if available in [p, p+avail),
// 0 if incomplete. Header-only length is returned via need for buffer growth.
inline std::size_t frame(const char* p, std::size_t avail, std::size_t& need) {
  if (avail < 5) {
    need = 5;
    return 0;
  }
  std::size_t n = 1 + std::size_t(util::be32(p + 1));
  need = n;
  return avail >= n ? n : 0;
}

// Column cursor over a DataRow body (after the int16 column count).
struct Row {
  const char* p;
  const char* end;
  int ncols;

  // Reads the next column. Returns false if the row is malformed. len = -1 for NULL.
  bool next(const char*& v, std::int32_t& len) {
    if (end - p < 4) return false;
    len = std::int32_t(util::be32(p));
    p += 4;
    if (len < 0) {
      v = nullptr;
      len = -1;
      return true;
    }
    if (end - p < len) return false;
    v = p;
    p += len;
    return true;
  }
};

inline Row row_of(const char* msg, std::size_t msg_len) {
  // msg points at 'D'; body starts at +5 with int16 column count.
  Row r{msg + 7, msg + msg_len, int(util::be16(msg + 5))};
  return r;
}

inline std::int64_t dec_int8(const char* v) { return std::int64_t(util::be64(v)); }
inline std::int32_t dec_int4(const char* v) { return std::int32_t(util::be32(v)); }
inline bool dec_bool(const char* v) { return v[0] != 0; }

// Iterates a binary one-dimensional text[] (or empty array) value.
struct TextArray {
  const char* p = nullptr;
  const char* end = nullptr;
  int remaining = 0;

  bool init(const char* v, std::int32_t len) {
    if (len < 12) return false;
    int ndim = int(util::be32(v));
    end = v + len;
    if (ndim == 0) {
      remaining = 0;
      p = v + 12;
      return true;
    }
    if (ndim != 1 || len < 20) return false;
    remaining = int(util::be32(v + 12));
    p = v + 20;
    return remaining >= 0;
  }
  bool next(const char*& s, std::int32_t& n) {
    if (remaining <= 0 || end - p < 4) return false;
    n = std::int32_t(util::be32(p));
    p += 4;
    if (n < 0) {  // NULL element
      s = nullptr;
      --remaining;
      return true;
    }
    if (end - p < n) return false;
    s = p;
    p += n;
    --remaining;
    return true;
  }
};

// Extracts the SQLSTATE ('C' field) from an ErrorResponse message into out[6].
void error_sqlstate(const char* msg, std::size_t len, char out[6]);
// Extracts the human-readable message ('M' field) for logging.
std::string error_message(const char* msg, std::size_t len);

}  // namespace pg
