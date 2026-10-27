#include "http.hpp"

#include <charconv>
#include <cstring>

#include "config.hpp"
#include "util.hpp"

namespace http {
namespace {

// Finds "\r\n\r\n" in [p, p + n); returns the offset just past it, or 0 if absent.
std::size_t find_header_end(const char* p, std::size_t n) {
  if (n < 4) return 0;  // also keeps a null pointer (empty input) away from memmem
  const void* hit = memmem(p, n, "\r\n\r\n", 4);
  return hit ? std::size_t(static_cast<const char*>(hit) - p) + 4 : 0;
}

std::string_view trim_ows(std::string_view v) {
  while (!v.empty() && (v.front() == ' ' || v.front() == '\t')) v.remove_prefix(1);
  while (!v.empty() && (v.back() == ' ' || v.back() == '\t')) v.remove_suffix(1);
  return v;
}

// Applies a Connection header value (comma-separated tokens) to keep_alive.
void apply_connection(std::string_view v, bool& keep_alive) {
  while (!v.empty()) {
    std::size_t comma = v.find(',');
    std::string_view tok = trim_ows(v.substr(0, comma));
    if (util::ieq(tok, "close")) keep_alive = false;
    else if (util::ieq(tok, "keep-alive")) keep_alive = true;
    if (comma == std::string_view::npos) break;
    v.remove_prefix(comma + 1);
  }
}

}  // namespace

ParseStatus parse_request(const char* data, std::size_t len, Request& out) {
  std::size_t scan = len < cfg::kMaxHeaderBytes + 4 ? len : cfg::kMaxHeaderBytes + 4;
  std::size_t hdr_end = find_header_end(data, scan);
  if (hdr_end == 0) return len > cfg::kMaxHeaderBytes ? ParseStatus::HeaderTooBig : ParseStatus::Incomplete;

  out = Request{};
  const char* p = data;
  const char* end = data + hdr_end - 2;  // points at the final CRLF of the header block

  // ---- request line: METHOD SP target SP HTTP/1.x CRLF ----
  const char* sp1 = static_cast<const char*>(std::memchr(p, ' ', std::size_t(end - p)));
  if (!sp1) return ParseStatus::BadRequest;
  std::string_view method(p, std::size_t(sp1 - p));
  if (method == "GET") out.method = Method::Get;
  else if (method == "POST") out.method = Method::Post;
  else if (method == "PUT") out.method = Method::Put;
  else if (method == "DELETE") out.method = Method::Delete;
  else out.method = Method::Other;
  const char* tstart = sp1 + 1;
  const char* sp2 = static_cast<const char*>(std::memchr(tstart, ' ', std::size_t(end - tstart)));
  if (!sp2 || sp2 == tstart) return ParseStatus::BadRequest;
  const char* line_end = static_cast<const char*>(memmem(sp2, std::size_t(end + 2 - sp2), "\r\n", 2));
  if (!line_end) return ParseStatus::BadRequest;
  std::string_view version(sp2 + 1, std::size_t(line_end - sp2 - 1));
  if (version == "HTTP/1.1") {
    out.http10 = false;
    out.keep_alive = true;
  } else if (version == "HTTP/1.0") {
    out.http10 = true;
    out.keep_alive = false;
  } else {
    return ParseStatus::BadRequest;
  }
  out.target = std::string_view(tstart, std::size_t(sp2 - tstart));
  std::size_t q = out.target.find('?');
  if (q == std::string_view::npos) {
    out.path = out.target;
  } else {
    out.path = out.target.substr(0, q);
    out.query = out.target.substr(q + 1);
  }
  // Fragments are never sent by clients; strip defensively from the query.
  if (std::size_t h = out.query.find('#'); h != std::string_view::npos) out.query = out.query.substr(0, h);

  // ---- headers ----
  bool have_length = false;
  std::int64_t content_length = 0;
  p = line_end + 2;
  while (p < end) {
    const char* eol = static_cast<const char*>(memmem(p, std::size_t(end + 2 - p), "\r\n", 2));
    if (!eol) return ParseStatus::BadRequest;
    if (*p == ' ' || *p == '\t') return ParseStatus::BadRequest;  // obsolete line folding
    const char* colon = static_cast<const char*>(std::memchr(p, ':', std::size_t(eol - p)));
    if (!colon || colon == p) return ParseStatus::BadRequest;
    std::string_view name(p, std::size_t(colon - p));
    std::string_view value = trim_ows(std::string_view(colon + 1, std::size_t(eol - colon - 1)));
    // Dispatch on length first: only four headers matter.
    switch (name.size()) {
      case 14:
        if (util::ieq(name, "content-length")) {
          std::int64_t n;
          if (!util::parse_uint(value, n)) return ParseStatus::BadRequest;
          if (have_length && n != content_length) return ParseStatus::BadRequest;
          have_length = true;
          content_length = n;
        }
        break;
      case 13:
        if (util::ieq(name, "authorization")) {
          out.authorization = value;
          out.has_authorization = true;
        }
        break;
      case 10:
        if (util::ieq(name, "connection")) apply_connection(value, out.keep_alive);
        break;
      case 17:
        if (util::ieq(name, "transfer-encoding")) return ParseStatus::Chunked;
        break;
      default:
        break;
    }
    p = eol + 2;
  }
  if (out.http10) out.keep_alive = false;  // HTTP/1.0 connections are closed after one response

  if (content_length > std::int64_t(cfg::kMaxBodyBytes)) return ParseStatus::BodyTooBig;
  std::size_t total = hdr_end + std::size_t(content_length);
  if (len < total) return ParseStatus::Incomplete;
  out.body = std::string_view(data + hdr_end, std::size_t(content_length));
  out.total_len = std::uint32_t(total);
  return ParseStatus::Complete;
}

long percent_decode_inplace(char* s, std::size_t len, bool plus_is_space) {
  auto hex = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  if (len == 0) return 0;  // empty views may carry a null pointer (e.g. "?limit" with no '=')
  // Fast path: nothing to decode.
  bool any = std::memchr(s, '%', len) != nullptr || (plus_is_space && std::memchr(s, '+', len) != nullptr);
  if (!any) return long(len);
  std::size_t w = 0;
  for (std::size_t r = 0; r < len; ++r) {
    char c = s[r];
    if (c == '%') {
      if (r + 2 >= len) return -1;  // need two hex digits after '%'
      int hi = hex(s[r + 1]), lo = hex(s[r + 2]);
      if (hi < 0 || lo < 0) return -1;
      s[w++] = char(hi * 16 + lo);
      r += 2;
    } else if (c == '+' && plus_is_space) {
      s[w++] = ' ';
    } else {
      s[w++] = c;
    }
  }
  return long(w);
}

std::string_view status_prefix(int status) {
  switch (status) {
    case 200: return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
    case 201: return "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: ";
    case 204: return "HTTP/1.1 204 No Content\r\n";
    case 400: return "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: ";
    case 401: return "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: ";
    case 403: return "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: ";
    case 404: return "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ";
    case 413: return "HTTP/1.1 413 Payload Too Large\r\nContent-Type: application/json\r\nContent-Length: ";
    case 422: return "HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nContent-Length: ";
    case 431: return "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Type: application/json\r\nContent-Length: ";
    case 503: return "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: ";
    default: return "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: ";
  }
}

char* write_headers_before(char* body, std::size_t body_len, int status, bool close) {
  static constexpr std::string_view kClose = "Connection: close\r\n";
  char tmp[cfg::kHeaderReserve];
  std::size_t n = 0;
  std::string_view pre = status_prefix(status);
  std::memcpy(tmp, pre.data(), pre.size());
  n = pre.size();
  if (status != 204) {
    auto r = std::to_chars(tmp + n, tmp + sizeof tmp, body_len);
    n = std::size_t(r.ptr - tmp);
    tmp[n++] = '\r';
    tmp[n++] = '\n';
  }
  if (close) {
    std::memcpy(tmp + n, kClose.data(), kClose.size());
    n += kClose.size();
  }
  tmp[n++] = '\r';
  tmp[n++] = '\n';
  char* start = body - n;
  std::memcpy(start, tmp, n);
  return start;
}

}  // namespace http
