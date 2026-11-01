#ifndef CORE_HTTP_H
#define CORE_HTTP_H

#include <stdbool.h>
#include <stddef.h>

#include "config.h"

/* http/1.1 request line + headers for one keep-alive conn. copies every token
 * it returns: a request never aliases the consumed input buf. body bytes left
 * to the caller, which waits for content_length */

typedef enum {
    HTTP_INCOMPLETE = 0,    // valid prefix, need more bytes
    HTTP_PARSED = 1,
    HTTP_INVALID = -1,      // answer 400
} http_result;

typedef enum {
    AUTH_NONE = 0,          // no Authorization header
    AUTH_TOKEN = 1,         // "Token <token>" (scheme case-sensitive per SPEC)
    AUTH_OTHER = 2,         // any other scheme
} http_auth_scheme;

typedef struct http_request {
    char method[HTTP_METHOD_MAX];
    char path[HTTP_PATH_MAX];       // raw, no query
    char query[HTTP_QUERY_MAX];     // raw, no '?'
    bool http10;
    bool keep_alive;                // may reuse conn
    long long content_length;
    http_auth_scheme auth;
    char auth_token[AUTH_TOKEN_MAX];
} http_request;

/* *header_len = request line + headers; body starts there, content_length long */
http_result http_parse(const char *buf, size_t len, size_t *header_len,
                       http_request *rq);

const char *http_status_text(int status);

#endif
