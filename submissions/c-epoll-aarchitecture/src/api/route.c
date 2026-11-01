#include "api/route.h"

#include <string.h>

#include "api/handlers.h"
#include "util.h"

/* one flat table; order matters only where a literal could match a capture:
 * /api/articles/feed before /api/articles/:slug */

#define ROUTE(method_, pattern_, handler_, auth_)                              \
    { .method = (method_), .pattern = (pattern_), .handler = (handler_),        \
      .auth = (auth_) }

static api_route routes[] = {
    ROUTE("POST", "/api/users", handle_users_register, AUTH_OPTIONAL),
    ROUTE("POST", "/api/users/login", handle_users_login, AUTH_OPTIONAL),
    ROUTE("GET", "/api/user", handle_user_get, AUTH_REQUIRED),
    ROUTE("PUT", "/api/user", handle_user_update, AUTH_REQUIRED),
    ROUTE("GET", "/api/profiles/:username", handle_profile_get, AUTH_OPTIONAL),
    ROUTE("POST", "/api/profiles/:username/follow", handle_profile_follow, AUTH_REQUIRED),
    ROUTE("DELETE", "/api/profiles/:username/follow", handle_profile_unfollow, AUTH_REQUIRED),
    ROUTE("GET", "/api/articles/feed", handle_articles_feed, AUTH_REQUIRED),
    ROUTE("GET", "/api/articles", handle_articles_list, AUTH_OPTIONAL),
    ROUTE("POST", "/api/articles", handle_article_create, AUTH_REQUIRED),
    ROUTE("GET", "/api/articles/:slug", handle_article_get, AUTH_OPTIONAL),
    ROUTE("PUT", "/api/articles/:slug", handle_article_update, AUTH_REQUIRED),
    ROUTE("DELETE", "/api/articles/:slug", handle_article_delete, AUTH_REQUIRED),
    ROUTE("POST", "/api/articles/:slug/favorite", handle_favorite_add, AUTH_REQUIRED),
    ROUTE("DELETE", "/api/articles/:slug/favorite", handle_favorite_remove, AUTH_REQUIRED),
    ROUTE("GET", "/api/articles/:slug/comments", handle_comments_list, AUTH_OPTIONAL),
    ROUTE("POST", "/api/articles/:slug/comments", handle_comments_create, AUTH_REQUIRED),
    ROUTE("DELETE", "/api/articles/:slug/comments/:id", handle_comment_delete, AUTH_REQUIRED),
    ROUTE("GET", "/api/tags", handle_tags_list, AUTH_IGNORE),
};

static const unsigned route_count = sizeof routes / sizeof routes[0];
static bool initialized;

static void compile_route(api_route *route) {
    const char *p = route->pattern;
    unsigned n = 0;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        const char *end = p;
        while (*end && *end != '/') end++;
        CHECK(n < API_MAX_SEGMENTS, "route %s has too many segments",
              route->pattern);
        route->seg[n].text = p;
        route->seg[n].len = (size_t)(end - p);
        route->seg[n].capture = *p == ':';
        n++;
        p = end;
    }
    route->nseg = n;
}

void route_init(void) {
    if (initialized) return;
    for (unsigned i = 0; i < route_count; i++) compile_route(&routes[i]);
    initialized = true;
}

const api_route *route_match(const char *method, const char *path,
                             api_capture captures[API_MAX_CAPTURES],
                             unsigned *ncaptures) {
    CHECK(initialized, "route_match before route_init");

    const char *part[API_MAX_SEGMENTS];
    size_t len[API_MAX_SEGMENTS];
    unsigned npart = 0;

    const char *p = path;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        const char *end = p;
        while (*end && *end != '/') end++;
        if (npart == API_MAX_SEGMENTS) return NULL;
        part[npart] = p;
        len[npart] = (size_t)(end - p);
        npart++;
        p = end;
    }

    *ncaptures = 0;
    for (unsigned i = 0; i < route_count; i++) {
        const api_route *route = &routes[i];
        if (strcmp(route->method, method) != 0) continue;
        if (route->nseg != npart) continue;

        unsigned ncaps = 0;
        bool match = true;
        for (unsigned j = 0; j < npart; j++) {
            if (route->seg[j].capture) {
                CHECK(ncaps < API_MAX_CAPTURES, "route %s captures too much",
                      route->pattern);
                captures[ncaps].ptr = part[j];
                captures[ncaps].len = len[j];
                ncaps++;
            } else if (route->seg[j].len != len[j] ||
                       memcmp(route->seg[j].text, part[j], len[j]) != 0) {
                match = false;
                break;
            }
        }
        if (match) {
            *ncaptures = ncaps;
            return route;
        }
    }
    return NULL;
}
