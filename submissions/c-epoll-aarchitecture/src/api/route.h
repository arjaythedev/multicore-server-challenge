#ifndef API_ROUTE_H
#define API_ROUTE_H

#include <stdbool.h>
#include <stddef.h>

/* routes compiled once at startup: patterns split into static segs, so a req
 * only walks the path. captures are (ptr,len) slices into req path; dispatcher
 * copies them into req arena */

#define API_MAX_SEGMENTS 8
#define API_MAX_CAPTURES 3      // deepest route: :slug + :id

typedef struct api_capture {
    const char *ptr;
    size_t len;
} api_capture;

typedef enum {
    AUTH_IGNORE = 0,    // never looks at Authorization
    AUTH_OPTIONAL,      // missing -> anon; present must be valid
    AUTH_REQUIRED,      // missing/invalid -> 401
} api_auth;

struct api_request;

typedef struct api_route {
    const char *method;
    const char *pattern;
    void (*handler)(struct api_request *);
    api_auth auth;

    unsigned nseg;
    struct {
        const char *text;
        size_t len;
        bool capture;
    } seg[API_MAX_SEGMENTS];
} api_route;

void route_init(void);

// NULL = no route match; caller sends 404
const api_route *route_match(const char *method, const char *path,
                             api_capture captures[API_MAX_CAPTURES],
                             unsigned *ncaptures);

#endif
