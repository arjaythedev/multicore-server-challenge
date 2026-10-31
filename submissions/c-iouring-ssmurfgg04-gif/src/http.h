/* http.h - one-shot request parse + route */
#pragma once
#include <stddef.h>

#include "conduit.h"

#define HTTP_INCOMPLETE ((size_t)0)
#define HTTP_ERROR ((size_t)-1)

/* does the span contain a percent escape (http.c) */
int pct_needs(const char *s, size_t n);

/* percent-decode into dst (dst needs n+1); returns length or (size_t)-1 */
size_t pct_decode(const char *s, size_t n, char *dst);

/* Parses one request at the start of [p, p+n), fills r and calls route(r).
 * Returns bytes consumed, HTTP_INCOMPLETE if the request needs more bytes,
 * HTTP_ERROR if the stream is unrecoverable. */
size_t http_request(const char *p, size_t n, req_t *r);
