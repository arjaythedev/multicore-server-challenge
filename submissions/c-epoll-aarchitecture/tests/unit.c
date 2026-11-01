// shitcoded by an AI; still better than the rest of the codebase

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "api/api.h"
#include "api/route.h"
#include "core/arena.h"
#include "core/buf.h"
#include "core/http.h"
#include "core/json.h"
#include "crypto/jwt.h"

static int failed;

#define EXPECT(cond)                                                          \
    do {                                                                      \
        if (!(cond)) {                                                        \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);            \
            failed++;                                                         \
        }                                                                     \
    } while (0)

static void test_json(void) {
    const char *error = NULL;
    const char *source = "{\"a\":1,\"b\":\"x\",\"c\":[true,null]}";
    json_node *node = json_parse(source, strlen(source), &error);
    EXPECT(node != NULL && error == NULL);
    if (!node) return;

    const json_node *a = json_get(node, "a");
    EXPECT(a && a->kind == JSON_NUM && a->num == 1 && a->is_int);
    const json_node *b = json_get(node, "b");
    EXPECT(b && b->kind == JSON_STR && strcmp(b->str, "x") == 0);
    const json_node *c = json_get(node, "c");
    EXPECT(c && c->kind == JSON_ARR && c->nchild == 2);
    EXPECT(json_get(node, "missing") == NULL);
    json_free(node);

    EXPECT(json_parse("{", 1, &error) == NULL && error != NULL);

    const char *number = "1.5";
    node = json_parse(number, strlen(number), &error);
    EXPECT(node && node->kind == JSON_NUM && !node->is_int);
    json_free(node);

    buf packed;
    buf_init(&packed);
    json_quote(&packed, "q\"\n");
    EXPECT(packed.len == 7 && memcmp(packed.data, "\"q\\\"\\n\"", 7) == 0);
    buf_free(&packed);

    // non-escape control bytes use the \u00xx form
    buf_init(&packed);
    json_quote(&packed, "\x01");
    EXPECT(packed.len == 8 && memcmp(packed.data, "\"\\u0001\"", 8) == 0);
    buf_free(&packed);
}

static void test_http(void) {
    const char *get = "GET /api/articles?limit=20&offset=5 HTTP/1.1\r\n"
                      "Host: x\r\nAuthorization: Token t1\r\n\r\n";
    http_request rq;
    size_t used = 0;
    memset(&rq, 0, sizeof rq);
    EXPECT(http_parse(get, strlen(get), &used, &rq) == HTTP_PARSED);
    EXPECT(strcmp(rq.method, "GET") == 0);
    EXPECT(strcmp(rq.path, "/api/articles") == 0);
    EXPECT(strcmp(rq.query, "limit=20&offset=5") == 0);
    EXPECT(used == strlen(get));
    EXPECT(rq.keep_alive);
    EXPECT(rq.auth == AUTH_TOKEN && strcmp(rq.auth_token, "t1") == 0);

    const char *close = "POST /api/users HTTP/1.1\r\nContent-Length: 12\r\n"
                        "Connection: close\r\n\r\n";
    memset(&rq, 0, sizeof rq);
    EXPECT(http_parse(close, strlen(close), &used, &rq) == HTTP_PARSED);
    EXPECT(rq.content_length == 12);
    EXPECT(!rq.keep_alive);
    EXPECT(used == strlen(close));

    const char *http10_keep = "GET /api/tags HTTP/1.0\r\n"
                              "Connection: keep-alive\r\n\r\n";
    memset(&rq, 0, sizeof rq);
    EXPECT(http_parse(http10_keep, strlen(http10_keep), &used, &rq)
           == HTTP_PARSED);
    EXPECT(rq.http10 && rq.keep_alive);

    const char *partial = "GET /api/tags HTTP/1.1\r\n";
    memset(&rq, 0, sizeof rq);
    EXPECT(http_parse(partial, strlen(partial), &used, &rq) == HTTP_INCOMPLETE);

    const char *bad = "NONSENSE\r\n\r\n";
    memset(&rq, 0, sizeof rq);
    EXPECT(http_parse(bad, strlen(bad), &used, &rq) == HTTP_INVALID);

    EXPECT(strcmp(http_status_text(201), "Created") == 0);
    EXPECT(strcmp(http_status_text(422), "Unprocessable Entity") == 0);
    EXPECT(strcmp(http_status_text(204), "No Content") == 0);
}

static void test_jwt(void) {
    buf token;
    buf_init(&token);
    long long now = (long long)time(NULL);
    EXPECT(jwt_mint(&token, 42, "secret", now));
    EXPECT(token.len > 0 && token.len < 512);

    char text[512];
    memcpy(text, token.data, token.len);
    text[token.len] = '\0';

    long long id = 0;
    EXPECT(jwt_verify(&id, text, "secret") && id == 42);
    EXPECT(!jwt_verify(&id, text, "other"));
    EXPECT(!jwt_verify(&id, "a.b.c", "secret"));

    char tampered[512];
    memcpy(tampered, text, token.len + 1);
    tampered[token.len - 5] = tampered[token.len - 5] == 'A' ? 'B' : 'A';
    EXPECT(!jwt_verify(&id, tampered, "secret"));

    buf expired;
    buf_init(&expired);
    EXPECT(jwt_mint(&expired, 7, "secret", now - JWT_TTL_SECONDS - 60));
    char expired_text[512];
    memcpy(expired_text, expired.data, expired.len);
    expired_text[expired.len] = '\0';
    EXPECT(!jwt_verify(&id, expired_text, "secret"));
    buf_free(&expired);
    buf_free(&token);
}

static void test_query(void) {
    char out[16];
    EXPECT(query_string("limit=20&offset=5", "limit", out, sizeof out)
           == QUERY_OK && strcmp(out, "20") == 0);
    EXPECT(query_string("limit=20&offset=5", "offset", out, sizeof out)
           == QUERY_OK && strcmp(out, "5") == 0);
    EXPECT(query_string("limit=20", "offset", out, sizeof out) == QUERY_ABSENT);
    EXPECT(query_string("limit=%zz", "limit", out, sizeof out) == QUERY_INVALID);
    EXPECT(query_string("limit=%2", "limit", out, sizeof out) == QUERY_INVALID);
    EXPECT(query_string("limit=%00", "limit", out, sizeof out) == QUERY_INVALID);
    EXPECT(query_string("q=a+b", "q", out, sizeof out) == QUERY_OK
           && strcmp(out, "a b") == 0);
    EXPECT(query_string("q=a%20b", "q", out, sizeof out) == QUERY_OK
           && strcmp(out, "a b") == 0);

    char small[4];
    EXPECT(query_string("q=abcdef", "q", small, sizeof small) == QUERY_INVALID);

    long long value = 0;
    EXPECT(query_integer("limit=20", "limit", &value) == QUERY_OK && value == 20);
    EXPECT(query_integer("limit=0005", "limit", &value) == QUERY_OK
           && value == 5);
    EXPECT(query_integer("", "limit", &value) == QUERY_ABSENT);
    EXPECT(query_integer("limit=", "limit", &value) == QUERY_INVALID);
    EXPECT(query_integer("limit=-1", "limit", &value) == QUERY_INVALID);
    EXPECT(query_integer("limit=abc", "limit", &value) == QUERY_INVALID);
    EXPECT(query_integer("limit=1234567890123456789", "limit", &value)
           == QUERY_INVALID);
}

static void test_buf_printf(void) {
    char content[257];
    memset(content, 'x', sizeof content - 1);
    content[sizeof content - 1] = '\0';

    buf b;
    buf_init(&b);
    buf_printf(&b, "%s", content);
    EXPECT(b.len == 256);
    EXPECT(b.cap > b.len);          /* room for the terminator */
    EXPECT(memcmp(b.data, content, b.len) == 0);
    buf_free(&b);
}

static void test_arena(void) {
    arena a;
    arena_init(&a);

    enum { N = 64 };
    char want[N][48];
    char *got[N];
    for (int i = 0; i < N; i++) {
        snprintf(want[i], sizeof want[i], "value-%03d-%s", i,
                 "xxxxxxxxxxxxxxxxxxxxxxxx");
        got[i] = arena_strdup(&a, want[i]);
    }
    for (int i = 0; i < N; i++) EXPECT(strcmp(got[i], want[i]) == 0);

    char *p = arena_printf(&a, "%lld", 1234567890123LL);
    EXPECT(strcmp(p, "1234567890123") == 0);

    arena_reset(&a);
    EXPECT(a.head == NULL);
}

static void test_body(void) {
    const char *source =
        "{\"user\":{\"username\":\"u\",\"email\":\"\",\"bio\":null,"
        "\"tagList\":[\"a\",\"b c\",\"q\\\"x\"]}}";
    const char *error = NULL;
    json_node *root = json_parse(source, strlen(source), &error);
    EXPECT(root != NULL);
    if (!root) return;

    api_request r;
    memset(&r, 0, sizeof r);
    arena_init(&r.arena);
    r.body = root;

    const json_node *user = body_object(&r, "user");
    EXPECT(user != NULL);
    EXPECT(body_object(&r, "article") == NULL);

    const char *text = NULL;
    EXPECT(body_string(user, "username", &text) == FIELD_OK
           && strcmp(text, "u") == 0);
    EXPECT(body_string(user, "email", &text) == FIELD_INVALID);
    EXPECT(body_string(user, "bio", &text) == FIELD_ABSENT);
    EXPECT(body_string(user, "missing", &text) == FIELD_ABSENT);
    EXPECT(body_string_allow_empty(user, "email", &text) == FIELD_OK
           && strcmp(text, "") == 0);

    char *tags = NULL;
    EXPECT(body_text_array(&r, json_get(user, "tagList"), &tags) == FIELD_OK);
    EXPECT(tags && strcmp(tags, "{\"a\",\"b c\",\"q\\\"x\"}") == 0);

    EXPECT(body_text_array(&r, NULL, &tags) == FIELD_ABSENT && tags == NULL);

    const char *empty_array = "{\"tagList\":[]}";
    json_node *empty = json_parse(empty_array, strlen(empty_array), &error);
    EXPECT(body_text_array(&r, json_get(empty, "tagList"), &tags) == FIELD_OK);
    EXPECT(tags && strcmp(tags, "{}") == 0);
    json_free(empty);

    const char *not_array = "{\"tagList\":\"x\"}";
    json_node *wrong = json_parse(not_array, strlen(not_array), &error);
    EXPECT(body_text_array(&r, json_get(wrong, "tagList"), &tags)
           == FIELD_INVALID);
    json_free(wrong);

    const char *with_empty = "{\"tagList\":[\"a\",\"\"]}";
    json_node *bad = json_parse(with_empty, strlen(with_empty), &error);
    EXPECT(body_text_array(&r, json_get(bad, "tagList"), &tags)
           == FIELD_INVALID);
    json_free(bad);

    json_free(root);
    arena_reset(&r.arena);
}

static void test_route(void) {
    route_init();

    api_capture captures[API_MAX_CAPTURES];
    unsigned ncaptures = 0;

    const api_route *route =
        route_match("GET", "/api/articles", captures, &ncaptures);
    EXPECT(route && strcmp(route->pattern, "/api/articles") == 0);
    EXPECT(route && route->auth == AUTH_OPTIONAL && ncaptures == 0);

    route = route_match("POST", "/api/articles", captures, &ncaptures);
    EXPECT(route && route->auth == AUTH_REQUIRED);

    route = route_match("GET", "/api/articles/feed", captures, &ncaptures);
    EXPECT(route && strcmp(route->pattern, "/api/articles/feed") == 0);

    route = route_match("GET", "/api/articles/some-slug/comments", captures,
                        &ncaptures);
    EXPECT(route &&
           strcmp(route->pattern, "/api/articles/:slug/comments") == 0);
    EXPECT(ncaptures == 1 && captures[0].len == strlen("some-slug") &&
           memcmp(captures[0].ptr, "some-slug", captures[0].len) == 0);

    route = route_match("DELETE", "/api/articles/s/comments/42", captures,
                        &ncaptures);
    EXPECT(route && strcmp(route->pattern,
                           "/api/articles/:slug/comments/:id") == 0);
    EXPECT(ncaptures == 2);
    EXPECT(captures[0].len == 1 && memcmp(captures[0].ptr, "s", 1) == 0);
    EXPECT(captures[1].len == 2 && memcmp(captures[1].ptr, "42", 2) == 0);

    route = route_match("GET", "/api/tags", captures, &ncaptures);
    EXPECT(route && route->auth == AUTH_IGNORE);

    EXPECT(route_match("PATCH", "/api/articles", captures, &ncaptures) == NULL);
    EXPECT(route_match("GET", "/api/nope", captures, &ncaptures) == NULL);
    EXPECT(route_match("GET", "/api/tags/extra", captures, &ncaptures) == NULL);

    // empty/repeated separators skipped, as in the old matcher
    route = route_match("GET", "//api//tags//", captures, &ncaptures);
    EXPECT(route && strcmp(route->pattern, "/api/tags") == 0);
}

int main(void) {
    test_json();
    test_http();
    test_jwt();
    test_query();
    test_buf_printf();
    test_arena();
    test_body();
    test_route();

    if (failed) {
        printf("%d check(s) failed\n", failed);
        return 1;
    }
    printf("all unit checks passed\n");
    return 0;
}
