/* HTTP/1.1 requests, parsed in place from received bytes, and responses framed with one header write.
 *
 * Responses are built body first: the body starts at HDR_GAP in its buffer, and http_finish writes the status
 * line and headers right-aligned into the gap, so header and body go out in a single send. */
#pragma once
#include "buf.h"

enum http_method { M_OTHER, M_GET, M_POST, M_PUT, M_DELETE };

#define HTTP_MAX_HEAD 8192
#define HTTP_MAX_BODY (1 << 20)

struct http_req {
    uint8_t method;
    bool keep_alive;
    bool has_auth;
    bool accept_gzip;
    const char *path, *query, *auth, *body;
    uint32_t path_len, query_len, auth_len, body_len;
};

/* Parses one request from p[0..n). Returns its total size (head + body) when complete, 0 when more bytes are
 * needed, HTTP_BAD for a malformed request, HTTP_TOO_LARGE when the head or body is over the limits. */
#define HTTP_BAD (-1)
#define HTTP_TOO_LARGE (-2)
ptrdiff_t http_parse(const char *p, size_t n, struct http_req *r);

/* ---- responses ---- */

#define HDR_GAP 128

/* Starts a response body in b (clears it and reserves the header gap). */
static inline void http_begin(struct buf *b) {
    b->len = 0;
    buf_reserve(b, HDR_GAP + 512);
    b->len = HDR_GAP;
}

/* Writes the head for the body already in b (JSON unless status is 204, which has no body). Returns the offset
 * where the response starts; it runs to b->len. */
size_t http_finish(struct buf *b, int status, bool keep_alive);
