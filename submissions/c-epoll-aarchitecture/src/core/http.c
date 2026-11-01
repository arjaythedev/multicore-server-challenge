#include "core/http.h"

#include <stdbool.h>
#include <string.h>

/* only the headers the conn state machine needs: Content-Length, Connection,
 * Authorization. names compare case-insensitively; values keep their bytes
 * (minus surrounding OWS). over-long block or target is INVALID, never
 * truncated */

static char lower(char ch) {
    return ch >= 'A' && ch <= 'Z' ? (char)(ch + ('a' - 'A')) : ch;
}

static bool name_is(const char *name, size_t len, const char *want) {
    size_t want_len = strlen(want);
    if (len != want_len) return false;
    for (size_t i = 0; i < len; i++) {
        if (lower(name[i]) != want[i]) return false;
    }
    return true;
}

static bool value_is(const char *value, size_t len, const char *want) {
    if (len != strlen(want)) return false;
    for (size_t i = 0; i < len; i++) {
        if (lower(value[i]) != want[i]) return false;
    }
    return true;
}

static void trim_ows(const char **s, const char **e) {
    while (*s < *e && (**s == ' ' || **s == '\t')) (*s)++;
    while (*e > *s && ((*e)[-1] == ' ' || (*e)[-1] == '\t')) (*e)--;
}

static bool copy_span(char *dst, size_t cap, const char *src, size_t len) {
    if (len >= cap) return false;
    memcpy(dst, src, len);
    dst[len] = '\0';
    return true;
}

static const char *header_end(const char *buf, size_t len) {
    const char *p = buf;
    const char *end = buf + len;
    while (p < end) {
        const char *cr = memchr(p, '\r', (size_t)(end - p));
        if (!cr) return NULL;
        if (end - cr >= 4 && cr[1] == '\n' && cr[2] == '\r' && cr[3] == '\n')
            return cr;
        p = cr + 1;
    }
    return NULL;
}

static bool parse_content_length(const char *value, size_t len,
                                 long long *out) {
    if (len == 0 || len > 18) return false;
    long long v = 0;
    for (size_t i = 0; i < len; i++) {
        char ch = value[i];
        if (ch < '0' || ch > '9') return false;
        v = v * 10 + (ch - '0');
    }
    *out = v;
    return true;
}

static void parse_connection(const char *value, size_t len, bool *close,
                             bool *keep_alive) {
    size_t at = 0;
    while (at < len) {
        size_t end = at;
        while (end < len && value[end] != ',') end++;
        const char *token = value + at;
        const char *token_end = value + end;
        trim_ows(&token, &token_end);
        if (value_is(token, (size_t)(token_end - token), "close")) *close = true;
        else if (value_is(token, (size_t)(token_end - token), "keep-alive"))
            *keep_alive = true;
        at = end + (end < len ? 1 : 0);
    }
}

static void parse_authorization(const char *value, size_t len,
                                http_request *rq) {
    if (len >= 6 && memcmp(value, "Token ", 6) == 0) {
        const char *token = value + 6;
        const char *token_end = value + len;
        trim_ows(&token, &token_end);
        rq->auth = AUTH_TOKEN;
        if (!copy_span(rq->auth_token, sizeof rq->auth_token, token,
                       (size_t)(token_end - token)))
            rq->auth_token[0] = '\0';   // too long to store
        return;
    }
    rq->auth = AUTH_OTHER;
}

http_result http_parse(const char *buf, size_t len, size_t *header_len,
                       http_request *rq) {
    const char *end = header_end(buf, len);
    if (!end) {
        return len > HTTP_HEADER_BLOCK_MAX ? HTTP_INVALID : HTTP_INCOMPLETE;
    }
    size_t block = (size_t)(end - buf);
    if (block > HTTP_HEADER_BLOCK_MAX) return HTTP_INVALID;

    memset(rq, 0, sizeof *rq);

    /* request line: METHOD SP TARGET SP HTTP/x.y. with no headers the block is
     * just the request line and its CR is the terminator at `end`; else the
     * first CR inside the block ends it */
    if (block == 0) return HTTP_INVALID;
    const char *line_end = memchr(buf, '\r', block);
    if (!line_end) line_end = end;
    const char *sp1 = memchr(buf, ' ', (size_t)(line_end - buf));
    if (!sp1) return HTTP_INVALID;
    const char *sp2 = memchr(sp1 + 1, ' ', (size_t)(line_end - sp1 - 1));
    if (!sp2 || sp2 == sp1 + 1) return HTTP_INVALID;

    if (!copy_span(rq->method, sizeof rq->method, buf, (size_t)(sp1 - buf)))
        return HTTP_INVALID;

    const char *target = sp1 + 1;
    size_t target_len = (size_t)(sp2 - target);
    if (target_len == 0) return HTTP_INVALID;

    const char *version = sp2 + 1;
    size_t version_len = (size_t)(line_end - version);
    if (version_len == 8 && memcmp(version, "HTTP/1.1", 8) == 0) {
        rq->http10 = false;
    } else if (version_len == 8 && memcmp(version, "HTTP/1.0", 8) == 0) {
        rq->http10 = true;
    } else {
        return HTTP_INVALID;
    }

    const char *qmark = memchr(target, '?', target_len);
    if (qmark) {
        if (!copy_span(rq->path, sizeof rq->path, target,
                       (size_t)(qmark - target)))
            return HTTP_INVALID;
        if (!copy_span(rq->query, sizeof rq->query, qmark + 1,
                       (size_t)(target + target_len - qmark - 1)))
            return HTTP_INVALID;
    } else {
        if (!copy_span(rq->path, sizeof rq->path, target, target_len))
            return HTTP_INVALID;
    }

    /* every line is "name: value"; unknown names ignored here */
    bool content_length_seen = false;
    bool connection_close = false;
    bool connection_keep_alive = false;
    bool authorization_seen = false;

    const char *p = line_end + 2;
    while (p < end) {
        const char *eol = memchr(p, '\r', (size_t)(end - p));
        /* last header line's CR is the one `end` points at */
        if (!eol) eol = end;
        const char *colon = memchr(p, ':', (size_t)(eol - p));
        if (!colon) return HTTP_INVALID;

        const char *value = colon + 1;
        const char *value_end = eol;
        trim_ows(&value, &value_end);
        size_t name_len = (size_t)(colon - p);
        size_t value_len = (size_t)(value_end - value);

        if (name_is(p, name_len, "content-length")) {
            long long n;
            if (content_length_seen || !parse_content_length(value, value_len, &n))
                return HTTP_INVALID;   // one unambiguous length
            rq->content_length = n;
            content_length_seen = true;
        } else if (name_is(p, name_len, "connection")) {
            parse_connection(value, value_len, &connection_close,
                             &connection_keep_alive);
        } else if (name_is(p, name_len, "authorization")) {
            if (!authorization_seen) {
                authorization_seen = true;
                parse_authorization(value, value_len, rq);
            }
        }

        p = eol + 2;
    }

    rq->keep_alive = !connection_close;
    if (rq->http10 && !connection_keep_alive) rq->keep_alive = false;

    *header_len = block + 4;
    return HTTP_PARSED;
}

const char *http_status_text(int status) {
    // *UNCRUSTIFY-OFF*
    switch (status) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 500: return "Internal Server Error";
    case 422: return "Unprocessable Entity";
    default:  return "Unknown";
    }
    // *UNCRUSTIFY-ON*
}
