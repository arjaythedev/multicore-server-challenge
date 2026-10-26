#include "http.h"

#include "util.h"

static inline char lower(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }

/* Case-insensitive match of a header name against a lowercase literal. */
static bool name_is(const char *s, size_t n, const char *lit, size_t litlen) {
    if (n != litlen) return false;
    for (size_t i = 0; i < n; i++)
        if (lower(s[i]) != lit[i]) return false;
    return true;
}
#define NAME_IS(s, n, lit) name_is((s), (n), (lit), sizeof(lit) - 1)

/* Does a comma-separated header value contain the token (case-insensitive)? */
static bool has_token(const char *v, size_t n, const char *tok, size_t toklen) {
    size_t i = 0;
    while (i < n) {
        while (i < n && (v[i] == ' ' || v[i] == '\t' || v[i] == ',')) i++;
        size_t start = i;
        while (i < n && v[i] != ',' && v[i] != ';') i++;
        size_t end = i;
        while (end > start && (v[end - 1] == ' ' || v[end - 1] == '\t')) end--;
        if (name_is(v + start, end - start, tok, toklen)) return true;
        while (i < n && v[i] != ',') i++;
    }
    return false;
}

ptrdiff_t http_parse(const char *p, size_t n, struct http_req *r) {
    /* Find the end of the head first: nothing is parsed until it is all here. */
    size_t limit = n < HTTP_MAX_HEAD ? n : HTTP_MAX_HEAD;
    const char *head_end = NULL;
    for (const char *q = p; (q = memchr(q, '\n', (size_t)(p + limit - q))) != NULL; q++) {
        if (q + 1 < p + limit && q[1] == '\n') {
            head_end = q + 2;
            break;
        }
        if (q + 2 < p + limit && q[1] == '\r' && q[2] == '\n') {
            head_end = q + 3;
            break;
        }
    }
    if (!head_end) return n >= HTTP_MAX_HEAD ? HTTP_TOO_LARGE : 0;

    memset(r, 0, sizeof *r);
    r->keep_alive = true;

    /* Request line: METHOD SP target SP HTTP/1.x */
    const char *line_end = memchr(p, '\n', (size_t)(head_end - p));
    const char *sp1 = memchr(p, ' ', (size_t)(line_end - p));
    if (!sp1) return HTTP_BAD;
    size_t mlen = (size_t)(sp1 - p);
    if (mlen == 3 && memcmp(p, "GET", 3) == 0) r->method = M_GET;
    else if (mlen == 4 && memcmp(p, "POST", 4) == 0) r->method = M_POST;
    else if (mlen == 3 && memcmp(p, "PUT", 3) == 0) r->method = M_PUT;
    else if (mlen == 6 && memcmp(p, "DELETE", 6) == 0) r->method = M_DELETE;
    else r->method = M_OTHER;
    const char *target = sp1 + 1;
    const char *sp2 = memchr(target, ' ', (size_t)(line_end - target));
    if (!sp2 || sp2 == target || *target != '/') return HTTP_BAD;
    const char *version = sp2 + 1;
    size_t vlen = (size_t)(line_end - version);
    if (vlen && version[vlen - 1] == '\r') vlen--;
    if (vlen != 8 || memcmp(version, "HTTP/1.", 7) != 0) return HTTP_BAD;
    if (version[7] == '0') r->keep_alive = false;
    else if (version[7] != '1') return HTTP_BAD;

    const char *qm = memchr(target, '?', (size_t)(sp2 - target));
    r->path = target;
    r->path_len = (uint32_t)((qm ? qm : sp2) - target);
    if (qm) {
        r->query = qm + 1;
        r->query_len = (uint32_t)(sp2 - qm - 1);
    }

    /* Headers. */
    int64_t content_length = 0;
    bool have_length = false;
    for (const char *h = line_end + 1; h < head_end;) {
        const char *eol = memchr(h, '\n', (size_t)(head_end - h));
        const char *end = eol;
        if (end > h && end[-1] == '\r') end--;
        if (end == h) break;  /* the blank line */
        const char *colon = memchr(h, ':', (size_t)(end - h));
        if (!colon || colon == h) return HTTP_BAD;
        size_t nlen = (size_t)(colon - h);
        const char *v = colon + 1;
        while (v < end && (*v == ' ' || *v == '\t')) v++;
        const char *vend = end;
        while (vend > v && (vend[-1] == ' ' || vend[-1] == '\t')) vend--;
        size_t vl = (size_t)(vend - v);

        switch (lower(h[0])) {
        case 'a':
            if (NAME_IS(h, nlen, "authorization")) {
                r->has_auth = true;
                r->auth = v;
                r->auth_len = (uint32_t)vl;
            } else if (NAME_IS(h, nlen, "accept-encoding")) {
                r->accept_gzip = has_token(v, vl, LIT("gzip"));
            }
            break;
        case 'c':
            if (NAME_IS(h, nlen, "content-length")) {
                int64_t cl;
                if (!parse_uint(v, vl, &cl) || (have_length && cl != content_length)) return HTTP_BAD;
                content_length = cl;
                have_length = true;
            } else if (NAME_IS(h, nlen, "connection")) {
                if (has_token(v, vl, LIT("close"))) r->keep_alive = false;
                else if (has_token(v, vl, LIT("keep-alive"))) r->keep_alive = true;
            }
            break;
        case 't':
            if (NAME_IS(h, nlen, "transfer-encoding")) return HTTP_BAD;  /* clients here always send a length */
            break;
        }
        h = eol + 1;
    }

    if (content_length > HTTP_MAX_BODY) return HTTP_TOO_LARGE;
    size_t head = (size_t)(head_end - p);
    if (n - head < (size_t)content_length) return 0;
    r->body = head_end;
    r->body_len = (uint32_t)content_length;
    return (ptrdiff_t)(head + (size_t)content_length);
}

static const char *status_line(int status, size_t *len) {
#define S(code, text)                                  \
    case code:                                         \
        *len = sizeof("HTTP/1.1 " #code " " text) - 1; \
        return "HTTP/1.1 " #code " " text
    switch (status) {
        S(200, "OK");
        S(201, "Created");
        S(204, "No Content");
        S(400, "Bad Request");
        S(401, "Unauthorized");
        S(403, "Forbidden");
        S(404, "Not Found");
        S(405, "Method Not Allowed");
        S(413, "Content Too Large");
        S(422, "Unprocessable Entity");
        S(503, "Service Unavailable");
    default:
        S(500, "Internal Server Error");
    }
#undef S
}

size_t http_finish(struct buf *b, int status, bool keep_alive) {
    char head[HDR_GAP];
    size_t n, sl;
    const char *line = status_line(status, &sl);
    size_t body = b->len - HDR_GAP;

    memcpy(head, line, sl);
    n = sl;
    if (status == 204) {
        memcpy(head + n, "\r\n", 2), n += 2;
    } else {
        static const char ct[] = "\r\nContent-Type: application/json\r\nContent-Length: ";
        memcpy(head + n, ct, sizeof ct - 1), n += sizeof ct - 1;
        n += fmt_u64(head + n, body);
        memcpy(head + n, "\r\n", 2), n += 2;
    }
    if (!keep_alive) {
        static const char cl[] = "Connection: close\r\n";
        memcpy(head + n, cl, sizeof cl - 1), n += sizeof cl - 1;
    }
    memcpy(head + n, "\r\n", 2), n += 2;
    if (status == 204) b->len = HDR_GAP;  /* no body, whatever was written */
    memcpy(b->p + HDR_GAP - n, head, n);
    return HDR_GAP - n;
}
