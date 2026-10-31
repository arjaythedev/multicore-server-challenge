/* http.c - request parsing for exactly what this API speaks.
 *
 * One validating pass: request line, then a header scan that interprets
 * only authorization, content-length, connection, transfer-encoding and
 * expect. The path is split into percent-decoded segments copied to the
 * request's arena (the receive buffer is compacted between requests), the
 * body is copied too (async handlers outlive the parse), and the
 * Authorization token is verified right here: signature and exp on every
 * request, no cache. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "http.h"
#include "json.h"
#include "jwt.h"
#include "util.h"

#define MAX_AUTH 1024

int pct_needs(const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if (s[i] == '%') return 1;
    return 0;
}

/* percent-decode into dst (dst needs n+1); returns length or (size_t)-1 */
size_t pct_decode(const char *s, size_t n, char *dst)
{
    char *o = dst;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '%') {
            if (i + 2 >= n) return (size_t)-1;
            int hi = s[i + 1], lo = s[i + 2];
            int hv = hi >= '0' && hi <= '9' ? hi - '0'
                   : hi >= 'a' && hi <= 'f' ? hi - 'a' + 10
                   : hi >= 'A' && hi <= 'F' ? hi - 'A' + 10 : -1;
            int lv = lo >= '0' && lo <= '9' ? lo - '0'
                   : lo >= 'a' && lo <= 'f' ? lo - 'a' + 10
                   : lo >= 'A' && lo <= 'F' ? lo - 'A' + 10 : -1;
            if (hv < 0 || lv < 0) return (size_t)-1;
            *o++ = (char)(hv << 4 | lv);
            i += 2;
        } else {
            *o++ = s[i];
        }
    }
    return (size_t)(o - dst);
}

static inline int ieq(const char *a, const char *lit, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if ((a[i] | 0x20) != lit[i]) return 0;
    return 1;
}

size_t http_request(const char *p, size_t n, req_t *r)
{
    const char *he = memmem(p, n, "\r\n\r\n", 4);
    if (!he) return n > MAX_HEADER ? HTTP_ERROR : HTTP_INCOMPLETE;
    const char *end = p + n;

    /* request line: METHOD SP TARGET SP HTTP/1.x */
    const char *le = memchr(p, '\r', (size_t)(he + 2 - p));
    if (!le || le[1] != '\n' || memchr(p, '\n', (size_t)(le - p))) return HTTP_ERROR;
    const char *sp1 = memchr(p, ' ', (size_t)(le - p));
    if (!sp1) return HTTP_ERROR;
    const char *tgt = sp1 + 1;
    const char *sp2 = memchr(tgt, ' ', (size_t)(le - tgt));
    if (!sp2 || le - sp2 - 1 != 8 || memcmp(sp2 + 1, "HTTP/1.", 7)) return HTTP_ERROR;
    int http11 = sp2[8] == '1';
    if (!http11 && sp2[8] != '0') return HTTP_ERROR;
    (void)http11;

    const char *q = memchr(tgt, '?', (size_t)(sp2 - tgt));
    size_t pl = (size_t)((q ? q : sp2) - tgt);

    const char *auth = NULL, *authend = NULL;
    size_t clen = 0;
    int has_cl = 0, chunked = 0;

    for (const char *l = le + 2; l < he + 2;) {
        const char *e = memchr(l, '\r', (size_t)(he + 2 - l));
        if (!e || e[1] != '\n' || memchr(l, '\n', (size_t)(e - l))) return HTTP_ERROR;
        const char *colon = memchr(l, ':', (size_t)(e - l));
        if (colon) {
            size_t nl = (size_t)(colon - l);
            const char *v = colon + 1;
            while (v < e && (*v == ' ' || *v == '\t')) v++;
            const char *ve = e;
            while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
            switch (nl) {
            case 10:
                if (ieq(l, "connection", 10)) {
                    if (ve - v == 5 && ieq(v, "close", 5)) r->conn_close = 1;
                }
                break;
            case 13:
                if (ieq(l, "authorization", 13)) { auth = v; authend = ve; }
                break;
            case 14:
                if (ieq(l, "content-length", 14)) {
                    if (v == ve) return HTTP_ERROR;
                    size_t cl = 0;
                    for (const char *x = v; x < ve; x++) {
                        if (*x < '0' || *x > '9') return HTTP_ERROR;
                        cl = cl * 10 + (size_t)(*x - '0');
                        if (cl > MAX_BODY) return HTTP_ERROR;
                    }
                    if (has_cl && cl != clen) return HTTP_ERROR;
                    clen = cl;
                    has_cl = 1;
                }
                break;
            case 17:
                if (ieq(l, "transfer-encoding", 17)) chunked = 1;
                break;
            }
        }
        l = e + 2;
    }
    if (chunked) return HTTP_ERROR; /* not spoken here */

    const char *b = he + 4;
    if ((size_t)(end - b) < clen) return HTTP_INCOMPLETE;

    /* method */
    size_t ml = (size_t)(sp1 - p);
    if (ml == 3 && !memcmp(p, "GET", 3)) r->method = M_GET;
    else if (ml == 4 && !memcmp(p, "POST", 4)) r->method = M_POST;
    else if (ml == 3 && !memcmp(p, "PUT", 3)) r->method = M_PUT;
    else if (ml == 6 && !memcmp(p, "DELETE", 6)) r->method = M_DELETE;
    else return HTTP_ERROR; /* not spoken: 400 is fine for the bench */

    /* path segments: /api/<seg>/... percent-decoded into the arena */
    if (pl < 5 || memcmp(tgt, "/api/", 5)) {
        r->nseg = 0;
    } else {
        const char *s = tgt + 5, *send = tgt + pl;
        while (s <= send && r->nseg < NSEG) {
            const char *slash = memchr(s, '/', (size_t)(send - s));
            const char *se = slash ? slash : send;
            size_t sl = (size_t)(se - s);
            if (pct_needs(s, sl)) {
                char *d = arena_alloc(r, sl + 1);
                size_t dl = pct_decode(s, sl, d);
                if (dl == (size_t)-1) return HTTP_ERROR;
                r->seg[r->nseg].p = d;
                r->seg[r->nseg].n = (uint32_t)dl;
            } else {
                r->seg[r->nseg].p = s;
                r->seg[r->nseg].n = (uint32_t)sl;
            }
            r->nseg++;
            if (!slash) break;
            s = slash + 1;
        }
        if (s < send && r->nseg == NSEG) return HTTP_ERROR; /* too deep */
    }
    if (q) {
        r->query.p = q + 1;
        r->query.n = (uint32_t)(sp2 - q - 1);
    }

    /* authorization: verify now, every request */
    if (auth && authend > auth) {
        size_t al = (size_t)(authend - auth);
        if (al > MAX_AUTH) return HTTP_ERROR;
        char *ac = arena_alloc(r, al + 1);
        memcpy(ac, auth, al);
        ac[al] = 0;
        r->has_token = 1;
        auth_t a;
        int k = check_auth(ac, al, now_realtime(), &a);
        if (k == 0) {
            r->viewer = a.uid;
            /* the token itself (after "Token ") is echoed by GET/PUT /api/user */
            const char *tok = ac;
            size_t tl = al;
            if (tl >= 6 && !memcmp(tok, "Token ", 6)) { tok += 6; tl -= 6; }
            char *tc = arena_alloc(r, tl + 1);
            memcpy(tc, tok, tl);
            tc[tl] = 0;
            r->auth_token.p = tc;
            r->auth_token.n = (uint32_t)tl;
        } else {
            r->auth_bad = 1;
        }
    }

    /* body (copied: async continuations outlive the parse) */
    if (clen) {
        char *bc = arena_alloc(r, clen);
        memcpy(bc, b, clen);
        r->body.p = bc;
        r->body.n = (uint32_t)clen;
    }
    return (size_t)(b + clen - p);
}
