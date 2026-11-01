#ifndef PG_STATEMENTS_H
#define PG_STATEMENTS_H

/* SQL surface: writes are single prepared statements, reads batched by
 * pg_read_kind; prepared once per conn */

typedef enum {
    PG_STMT_USERS_INSERT = 0,
    PG_STMT_USERS_UPDATE,
    PG_STMT_FOLLOWS_INSERT,
    PG_STMT_FOLLOWS_DELETE,
    PG_STMT_ARTICLE_INSERT,
    PG_STMT_ARTICLE_UPDATE,
    PG_STMT_ARTICLE_DELETE,
    PG_STMT_FAVORITES_INSERT,
    PG_STMT_FAVORITES_DELETE,
    PG_STMT_COMMENTS_INSERT,
    PG_STMT_COMMENTS_DELETE,
    PG_STMT_COUNT,
} pg_stmt;

typedef enum {
    PG_READ_TAGS = 0,
    PG_READ_ARTICLE_SLUG,
    PG_READ_COMMENTS,
    PG_READ_PROFILE,
    PG_READ_USER_ID,
    PG_READ_USER_EMAIL,
    PG_READ_LIST,
    PG_READ_COUNT,
} pg_read_kind;

/* PG_READ_LIST branches per request on this kind (the r.t column) */
typedef enum {
    PG_LIST_ALL = 0,
    PG_LIST_TAG,
    PG_LIST_AUTHOR,
    PG_LIST_FAVORITED,
    PG_LIST_FEED,
} pg_list_kind;

extern const char *const PG_STMT_SQL[PG_STMT_COUNT];
extern const unsigned char PG_STMT_PARAM_COUNT[PG_STMT_COUNT];
extern const unsigned char PG_STMT_SOLO[PG_STMT_COUNT];

extern const char *const PG_READ_SQL[PG_READ_COUNT];
extern const unsigned char PG_READ_PARAM_COUNT[PG_READ_COUNT];

/* session settings, once per conn before prepares */
extern const char *const PG_SESSION_INIT;

#endif
