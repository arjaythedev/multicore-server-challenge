// Minimal, allocation-free HTTP/1.1 request parser and response-header writer.
//
// The parser works on a contiguous byte range holding at least one request. It returns string views into that
// range; percent-decoding happens later, in place, on the request's own copy of the bytes.
#pragma once
#include <cstdint>
#include <string_view>

namespace http {

enum class Method : std::uint8_t { Get, Post, Put, Delete, Other };

enum class ParseStatus : std::uint8_t {
  Complete,      // one full request (headers + body) is available
  Incomplete,    // need more bytes
  BadRequest,    // malformed: respond 400 and close
  HeaderTooBig,  // header section over the limit: 431 and close
  BodyTooBig,    // Content-Length over the limit: 413 and close
  Chunked,       // Transfer-Encoding present: 400 and close (bodies use Content-Length only)
};

struct Request {
  Method method = Method::Other;
  bool http10 = false;
  bool keep_alive = true;           // after Connection header / version rules
  std::string_view target;          // raw request target (path + optional query)
  std::string_view path;            // target before '?'
  std::string_view query;           // after '?', may be empty
  std::string_view authorization;   // raw header value, empty if absent
  bool has_authorization = false;
  std::string_view body;
  std::uint32_t total_len = 0;      // bytes consumed by this request (headers + body)
};

// Parses one request from [data, data + len). On Complete, `out` is filled and out.total_len says how many bytes
// it used (the rest belong to pipelined requests).
ParseStatus parse_request(const char* data, std::size_t len, Request& out);

// Decodes %XX escapes in place (and '+' to space when plus_is_space). Returns the decoded length, or -1 if an
// escape is malformed. Decoded output never exceeds the input length.
long percent_decode_inplace(char* s, std::size_t len, bool plus_is_space);

// Status line + fixed headers for the given status; the caller appends Content-Length digits and CRLFCRLF.
std::string_view status_prefix(int status);

// Writes the complete header block for a JSON (or empty 204) response so that it ends exactly at `body`.
// Returns a pointer to the first header byte. The caller must have reserved cfg::kHeaderReserve bytes before body.
char* write_headers_before(char* body, std::size_t body_len, int status, bool close);

}  // namespace http
