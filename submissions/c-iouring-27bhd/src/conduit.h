#ifndef CONDUIT_H
#define CONDUIT_H

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>

typedef enum {
    HTTP_METHOD_GET = 1,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
    HTTP_METHOD_DELETE,
    HTTP_METHOD_OTHER
} http_method_t;

typedef struct {
    http_method_t method;
    char path[512];
    int path_len;
    char query[512];
    int query_len;

    // Extracted path params (e.g. :username, :slug, :id)
    char param1[256];
    char param2[256];

    // Auth
    int64_t viewer_id;
    char token[512];
    bool has_auth_header;
    bool auth_invalid;

    // Body
    const char *body;
    int body_len;
} http_req_t;

typedef struct {
    char *buf;
    int len;
    int cap;
    int status;
} http_res_t;

static inline void res_init(http_res_t *res, char *buf, int cap) {
    res->buf = buf;
    res->len = 0;
    res->cap = cap;
    res->status = 200;
}

static inline void res_append(http_res_t *res, const char *s, int slen) {
    if (res->len + slen < res->cap) {
        memcpy(res->buf + res->len, s, slen);
        res->len += slen;
        res->buf[res->len] = '\0';
    }
}

static inline void res_append_str(http_res_t *res, const char *s) {
    res_append(res, s, (int)strlen(s));
}

#define RES_APPEND_LIT(res, lit) res_append((res), (lit), sizeof(lit) - 1)


static inline void res_error(http_res_t *res, int status, const char *msg) {
    res->status = status;
    res->len = 0;
    res_append_str(res, "{\"errors\":{\"body\":[\"");
    res_append_str(res, msg);
    res_append_str(res, "\"]}}");
}

#endif // CONDUIT_H
