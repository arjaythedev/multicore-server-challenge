#include "pg.hpp"

#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <vector>

#include "config.hpp"
#include "sql.hpp"

namespace pg {
namespace {

std::string pct_decode(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '%' && i + 2 < s.size()) {
      auto h = [](char c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; };
      out.push_back(char(h(s[i + 1]) * 16 + h(s[i + 2])));
      i += 2;
    } else {
      out.push_back(s[i]);
    }
  }
  return out;
}

// ---- blocking socket I/O with a deadline (startup and reconnect only) ----
constexpr int kIoTimeoutMs = 10000;

bool write_all(int fd, const void* p, std::size_t n) {
  const char* c = static_cast<const char*>(p);
  while (n) {
    ssize_t w = ::send(fd, c, n, MSG_NOSIGNAL);
    if (w < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    c += w;
    n -= std::size_t(w);
  }
  return true;
}

bool read_exact(int fd, char* p, std::size_t n) {
  while (n) {
    pollfd pfd{fd, POLLIN, 0};
    int pr = ::poll(&pfd, 1, kIoTimeoutMs);
    if (pr <= 0) {
      if (pr < 0 && errno == EINTR) continue;
      return false;
    }
    ssize_t r = ::recv(fd, p, n, 0);
    if (r <= 0) {
      if (r < 0 && errno == EINTR) continue;
      return false;
    }
    p += r;
    n -= std::size_t(r);
  }
  return true;
}

// Reads one message: type byte and body (without the length field).
bool read_msg(int fd, char& type, std::vector<char>& body) {
  char hdr[5];
  if (!read_exact(fd, hdr, 5)) return false;
  type = hdr[0];
  std::uint32_t len = util::be32(hdr + 1);
  if (len < 4 || len > (1u << 30)) return false;
  body.resize(len - 4);
  return len == 4 || read_exact(fd, body.data(), len - 4);
}

void put_msg(std::vector<char>& out, char type, std::string_view body) {
  if (type) out.push_back(type);
  char len[4];
  util::put32(len, std::uint32_t(body.size() + 4));
  out.insert(out.end(), len, len + 4);
  out.insert(out.end(), body.begin(), body.end());
}

std::string b64(const unsigned char* p, int n) {
  std::string s(std::size_t(4 * ((n + 2) / 3)) + 1, '\0');
  int w = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(s.data()), p, n);
  s.resize(std::size_t(w));
  return s;
}

std::vector<unsigned char> unb64(std::string_view s) {
  std::vector<unsigned char> out(s.size() / 4 * 3 + 3);
  int n = EVP_DecodeBlock(out.data(), reinterpret_cast<const unsigned char*>(s.data()), int(s.size()));
  if (n < 0) return {};
  // EVP_DecodeBlock counts padding bytes as output; trim them.
  std::size_t pad = 0;
  if (!s.empty() && s.back() == '=') ++pad;
  if (s.size() > 1 && s[s.size() - 2] == '=') ++pad;
  out.resize(std::size_t(n) - pad);
  return out;
}

void hmac256(const unsigned char* key, std::size_t klen, std::string_view msg, unsigned char out[32]) {
  unsigned int olen = 32;
  HMAC(EVP_sha256(), key, int(klen), reinterpret_cast<const unsigned char*>(msg.data()), msg.size(), out, &olen);
}

std::string_view attr(std::string_view msg, char key) {
  // Finds "k=value" in a comma-separated SCRAM message.
  std::size_t i = 0;
  while (i < msg.size()) {
    std::size_t comma = msg.find(',', i);
    std::string_view part = msg.substr(i, comma == std::string_view::npos ? std::string_view::npos : comma - i);
    if (part.size() >= 2 && part[0] == key && part[1] == '=') return part.substr(2);
    if (comma == std::string_view::npos) break;
    i = comma + 1;
  }
  return {};
}

bool scram(int fd, const ConnInfo& ci, std::string_view mechanisms, std::string& err) {
  bool has = false;
  for (std::size_t i = 0; i < mechanisms.size();) {
    std::size_t z = mechanisms.find('\0', i);
    if (z == std::string_view::npos || z == i) break;
    if (mechanisms.substr(i, z - i) == "SCRAM-SHA-256") has = true;
    i = z + 1;
  }
  if (!has) {
    err = "server offers no SCRAM-SHA-256";
    return false;
  }
  unsigned char rnd[18];
  RAND_bytes(rnd, sizeof rnd);
  std::string cnonce = b64(rnd, sizeof rnd);
  std::string client_first_bare = "n=,r=" + cnonce;
  std::string client_first = "n,," + client_first_bare;

  std::string body = "SCRAM-SHA-256";
  body.push_back('\0');
  char l[4];
  util::put32(l, std::uint32_t(client_first.size()));
  body.append(l, 4);
  body += client_first;
  std::vector<char> out;
  put_msg(out, 'p', body);
  if (!write_all(fd, out.data(), out.size())) {
    err = "send SASLInitialResponse failed";
    return false;
  }

  char type;
  std::vector<char> msg;
  if (!read_msg(fd, type, msg) || type != 'R' || msg.size() < 4 || util::be32(msg.data()) != 11) {
    err = "expected AuthenticationSASLContinue";
    return false;
  }
  std::string server_first(msg.data() + 4, msg.size() - 4);
  std::string_view nonce = attr(server_first, 'r'), salt64 = attr(server_first, 's'), iters = attr(server_first, 'i');
  if (nonce.substr(0, cnonce.size()) != cnonce || salt64.empty() || iters.empty()) {
    err = "bad SCRAM server-first message";
    return false;
  }
  std::vector<unsigned char> salt = unb64(salt64);
  int iterations = std::atoi(std::string(iters).c_str());
  if (salt.empty() || iterations <= 0) {
    err = "bad SCRAM salt/iterations";
    return false;
  }
  unsigned char salted[32];
  PKCS5_PBKDF2_HMAC(ci.password.data(), int(ci.password.size()), salt.data(), int(salt.size()), iterations,
                    EVP_sha256(), 32, salted);
  unsigned char client_key[32], stored_key[32], server_key[32], client_sig[32], server_sig[32], proof[32];
  hmac256(salted, 32, "Client Key", client_key);
  SHA256(client_key, 32, stored_key);
  hmac256(salted, 32, "Server Key", server_key);
  std::string final_wo_proof = "c=biws,r=" + std::string(nonce);
  std::string auth_message = client_first_bare + "," + server_first + "," + final_wo_proof;
  hmac256(stored_key, 32, auth_message, client_sig);
  hmac256(server_key, 32, auth_message, server_sig);
  for (int i = 0; i < 32; ++i) proof[i] = client_key[i] ^ client_sig[i];
  std::string client_final = final_wo_proof + ",p=" + b64(proof, 32);
  out.clear();
  put_msg(out, 'p', client_final);
  if (!write_all(fd, out.data(), out.size())) {
    err = "send SASLResponse failed";
    return false;
  }
  if (!read_msg(fd, type, msg)) {
    err = "connection closed during SCRAM";
    return false;
  }
  if (type == 'E') {
    err = "authentication failed (check DATABASE_URL credentials)";
    return false;
  }
  if (type != 'R' || msg.size() < 4 || util::be32(msg.data()) != 12) {
    err = "expected AuthenticationSASLFinal";
    return false;
  }
  std::string server_final(msg.data() + 4, msg.size() - 4);
  std::vector<unsigned char> v = unb64(attr(server_final, 'v'));
  if (v.size() != 32 || std::memcmp(v.data(), server_sig, 32) != 0) {
    err = "server signature mismatch";
    return false;
  }
  return true;
}

}  // namespace

bool parse_url(std::string_view url, ConnInfo& out) {
  std::string_view rest;
  if (url.starts_with("postgres://")) rest = url.substr(11);
  else if (url.starts_with("postgresql://")) rest = url.substr(13);
  else return false;
  std::size_t at = rest.rfind('@');
  if (at != std::string_view::npos) {
    std::string_view cred = rest.substr(0, at);
    std::size_t colon = cred.find(':');
    out.user = pct_decode(cred.substr(0, colon));
    if (colon != std::string_view::npos) out.password = pct_decode(cred.substr(colon + 1));
    rest = rest.substr(at + 1);
  }
  std::size_t slash = rest.find('/');
  std::string_view hostport = rest.substr(0, slash);
  std::string_view db = slash == std::string_view::npos ? std::string_view{} : rest.substr(slash + 1);
  if (std::size_t q = db.find('?'); q != std::string_view::npos) db = db.substr(0, q);
  std::size_t colon = hostport.rfind(':');
  if (colon != std::string_view::npos && hostport.find(']') == std::string_view::npos) {
    out.host = std::string(hostport.substr(0, colon));
    out.port = std::string(hostport.substr(colon + 1));
  } else if (!hostport.empty()) {
    out.host = std::string(hostport);
  }
  out.dbname = db.empty() ? out.user : pct_decode(db);
  return !out.user.empty();
}

int connect_blocking(const ConnInfo& ci, std::string& err) {
  addrinfo hints{}, *res = nullptr;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  if (int rc = getaddrinfo(ci.host.c_str(), ci.port.c_str(), &hints, &res); rc != 0) {
    err = std::string("getaddrinfo: ") + gai_strerror(rc);
    return -1;
  }
  int fd = -1;
  for (addrinfo* a = res; a; a = a->ai_next) {
    fd = ::socket(a->ai_family, a->ai_socktype | SOCK_CLOEXEC, a->ai_protocol);
    if (fd < 0) continue;
    if (::connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
    ::close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) {
    err = std::string("connect: ") + std::strerror(errno);
    return -1;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

  auto fail = [&](const std::string& why) {
    err = why;
    ::close(fd);
    return -1;
  };

  // StartupMessage: protocol 3.0, user, database, session options.
  std::string body;
  char v[4];
  util::put32(v, 196608);
  body.append(v, 4);
  auto kv = [&](const char* k, const std::string& val) {
    body += k;
    body.push_back('\0');
    body += val;
    body.push_back('\0');
  };
  kv("user", ci.user);
  kv("database", ci.dbname);
  kv("options", "-c jit=off -c max_parallel_workers_per_gather=0 -c plan_cache_mode=force_generic_plan -c statement_timeout=" +
                    std::to_string(cfg::kPgStatementTimeoutMs));
  kv("application_name", "conduit-cpp");
  body.push_back('\0');
  std::vector<char> out;
  put_msg(out, 0, body);
  if (!write_all(fd, out.data(), out.size())) return fail("send startup failed");

  char type;
  std::vector<char> msg;
  while (true) {
    if (!read_msg(fd, type, msg)) return fail("connection closed during startup");
    if (type == 'E') return fail("startup error: " + std::string(msg.begin(), msg.end()));
    if (type != 'R' || msg.size() < 4) return fail("unexpected message during auth");
    std::uint32_t code = util::be32(msg.data());
    if (code == 0) break;  // AuthenticationOk (also reached after SCRAM)
    if (code == 10) {
      if (!scram(fd, ci, std::string_view(msg.data() + 4, msg.size() - 4), err)) {
        ::close(fd);
        return -1;
      }
      continue;
    }
    return fail("unsupported auth method " + std::to_string(code) + " (need SCRAM-SHA-256)");
  }
  // ParameterStatus / BackendKeyData until ReadyForQuery.
  while (true) {
    if (!read_msg(fd, type, msg)) return fail("connection closed before ready");
    if (type == 'Z') break;
    if (type == 'E') return fail("error before ready");
  }

  // Prepare every statement, then one Sync.
  out.clear();
  for (int i = 0; i < sql::kStmtCount; ++i) {
    const sql::StmtDef& d = sql::kStmts[i];
    std::string b = "s" + std::to_string(i);
    b.push_back('\0');
    b += d.text;
    b.push_back('\0');
    char n2[2];
    util::put16(n2, d.nparams);
    b.append(n2, 2);
    for (int k = 0; k < d.nparams; ++k) {
      char o[4];
      util::put32(o, d.types[k]);
      b.append(o, 4);
    }
    put_msg(out, 'P', b);
  }
  // Batched forms: same statement ids, named "b<id>", array parameter types.
  for (int i = 0; i < sql::kStmtCount; ++i) {
    if (!sql::batchable(i)) continue;
    const sql::StmtDef& d = sql::kStmts[i];
    std::string b = "b" + std::to_string(i);
    b.push_back('\0');
    b += sql::batched_text(i);
    b.push_back('\0');
    char n2[2];
    util::put16(n2, d.nparams);
    b.append(n2, 2);
    for (int k = 0; k < d.nparams; ++k) {
      char o[4];
      util::put32(o, sql::array_oid(d.types[k]));
      b.append(o, 4);
    }
    put_msg(out, 'P', b);
  }
  // Shared-enrichment list forms: own ids after kStmtCount, named "s<id>", array parameters of their list kind.
  for (int i = sql::kStmtCount; i < sql::kStmtTotal; ++i) {
    const sql::StmtDef& d = sql::kStmts[sql::base_kind(i)];
    std::string b = "s" + std::to_string(i);
    b.push_back('\0');
    b += sql::shared_text(i);
    b.push_back('\0');
    char n2[2];
    util::put16(n2, d.nparams);
    b.append(n2, 2);
    for (int k = 0; k < d.nparams; ++k) {
      char o[4];
      util::put32(o, sql::array_oid(d.types[k]));
      b.append(o, 4);
    }
    put_msg(out, 'P', b);
  }
  put_msg(out, 'S', "");
  if (!write_all(fd, out.data(), out.size())) return fail("send Parse failed");
  std::string perr;
  while (true) {
    if (!read_msg(fd, type, msg)) return fail("connection closed while preparing");
    if (type == 'E' && perr.empty()) {
      std::vector<char> full(5 + msg.size());
      full[0] = 'E';
      util::put32(full.data() + 1, std::uint32_t(msg.size() + 4));
      std::memcpy(full.data() + 5, msg.data(), msg.size());
      perr = error_message(full.data(), full.size());
    }
    if (type == 'Z') break;
  }
  if (!perr.empty()) return fail("prepare failed: " + perr);
  return fd;
}

// ---- Bind encoding ----
Bind::Bind(PgOut& out, int stmt_id, int nparams, char prefix) : out_(out), nparams_(nparams) {
  out_.reserve(64);
  start_ = out_.len;
  char* p = out_.data + out_.len;
  p[0] = 'B';
  // length filled in finish()
  p[5] = '\0';  // unnamed portal
  int n = 6;
  p[n++] = prefix;
  if (stmt_id >= 10) p[n++] = char('0' + stmt_id / 10);
  p[n++] = char('0' + stmt_id % 10);
  p[n++] = '\0';
  util::put16(p + n, 1);  // one format code applies to all parameters
  util::put16(p + n + 2, 1);  // binary
  util::put16(p + n + 4, std::uint16_t(nparams));
  out_.len += std::size_t(n + 6);
}

void Bind::int8(std::int64_t v) {
  out_.reserve(12);
  char* p = out_.data + out_.len;
  util::put32(p, 8);
  util::put64(p + 4, std::uint64_t(v));
  out_.len += 12;
  ++written_;
}
void Bind::int4(std::int32_t v) {
  out_.reserve(8);
  char* p = out_.data + out_.len;
  util::put32(p, 4);
  util::put32(p + 4, std::uint32_t(v));
  out_.len += 8;
  ++written_;
}
void Bind::text(std::string_view s) {
  out_.reserve(4 + s.size());
  char* p = out_.data + out_.len;
  util::put32(p, std::uint32_t(s.size()));
  if (!s.empty()) std::memcpy(p + 4, s.data(), s.size());
  out_.len += 4 + s.size();
  ++written_;
}
void Bind::null() {
  out_.reserve(4);
  util::put32(out_.data + out_.len, 0xFFFFFFFFu);
  out_.len += 4;
  ++written_;
}
void Bind::text_array(const std::string_view* items, int n) {
  std::size_t bytes = n ? 20 : 12;
  for (int i = 0; i < n; ++i) bytes += 4 + items[i].size();
  out_.reserve(4 + bytes);
  char* p = out_.data + out_.len;
  util::put32(p, std::uint32_t(bytes));
  p += 4;
  util::put32(p, n ? 1 : 0);  // ndim
  util::put32(p + 4, 0);      // no NULLs
  util::put32(p + 8, sql::kText);
  p += 12;
  if (n) {
    util::put32(p, std::uint32_t(n));
    util::put32(p + 4, 1);  // lower bound
    p += 8;
    for (int i = 0; i < n; ++i) {
      util::put32(p, std::uint32_t(items[i].size()));
      std::memcpy(p + 4, items[i].data(), items[i].size());
      p += 4 + items[i].size();
    }
  }
  out_.len += 4 + bytes;
  ++written_;
}

std::size_t Bind::param_begin() {
  out_.reserve(4);
  std::size_t at = out_.len;
  out_.len += 4;
  return at;
}
void Bind::param_end(std::size_t at) {
  util::put32(out_.data + at, std::uint32_t(out_.len - at - 4));
  ++written_;
}
void Bind::append(const void* p, std::size_t n) {
  out_.reserve(n);
  std::memcpy(out_.data + out_.len, p, n);
  out_.len += n;
}
void Bind::append_be32(std::uint32_t v) {
  out_.reserve(4);
  util::put32(out_.data + out_.len, v);
  out_.len += 4;
}
void Bind::append_be64(std::uint64_t v) {
  out_.reserve(8);
  util::put64(out_.data + out_.len, v);
  out_.len += 8;
}

void Bind::finish() {
  out_.reserve(4 + 10);
  char* p = out_.data + out_.len;
  util::put16(p, 1);  // one result format code for all columns
  util::put16(p + 2, 1);  // binary
  out_.len += 4;
  util::put32(out_.data + start_ + 1, std::uint32_t(out_.len - start_ - 1));
  // Execute: unnamed portal, no row limit.
  p = out_.data + out_.len;
  p[0] = 'E';
  util::put32(p + 1, 9);
  p[5] = '\0';
  util::put32(p + 6, 0);
  out_.len += 10;
  (void)nparams_;
  (void)written_;
}

void sync(PgOut& out) {
  out.reserve(5);
  char* p = out.data + out.len;
  p[0] = 'S';
  util::put32(p + 1, 4);
  out.len += 5;
}

void error_sqlstate(const char* msg, std::size_t len, char out[6]) {
  std::memcpy(out, "XX000", 6);
  const char* p = msg + 5;
  const char* end = msg + len;
  while (p < end && *p) {
    char f = *p++;
    const char* z = static_cast<const char*>(std::memchr(p, 0, std::size_t(end - p)));
    if (!z) return;
    if (f == 'C' && z - p == 5) {
      std::memcpy(out, p, 5);
      out[5] = 0;
      return;
    }
    p = z + 1;
  }
}

std::string error_message(const char* msg, std::size_t len) {
  std::string out;
  const char* p = msg + 5;
  const char* end = msg + len;
  while (p < end && *p) {
    char f = *p++;
    const char* z = static_cast<const char*>(std::memchr(p, 0, std::size_t(end - p)));
    if (!z) break;
    if (f == 'C' || f == 'M') {
      if (!out.empty()) out += ' ';
      out.append(p, std::size_t(z - p));
    }
    p = z + 1;
  }
  return out;
}

}  // namespace pg
