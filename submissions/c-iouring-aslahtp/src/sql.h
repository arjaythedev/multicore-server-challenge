/* Every SQL statement the server runs, prepared once per connection at startup under the name "s<index>".
 * Each entry also lists the parameter types sent and the result column types expected; startup checks the
 * column types against the live database (Describe), so a schema surprise fails at start, not mid-run. */
#pragma once
#include "common.h"

enum stmt {
    S_TAGS,
    S_USER_INSERT,
    S_USER_BY_EMAIL,
    S_USER_BY_ID,
    S_USER_UPDATE,
    S_PROFILE,
    S_USER_BY_NAME,
    S_FOLLOW,
    S_UNFOLLOW,
    S_LIST_ALL,
    S_COUNT_ALL,
    S_LIST_TAG,
    S_COUNT_TAG,
    S_LIST_AUTHOR,
    S_COUNT_AUTHOR,
    S_LIST_FAVORITED,
    S_COUNT_FAVORITED,
    S_FEED,
    S_COUNT_FEED,
    S_ARTICLE_BY_SLUG,
    S_ARTICLE_BY_ID,
    S_ARTICLE_INSERT,
    S_TAGS_INSERT,
    S_ARTICLE_TAGS_INSERT,
    S_ARTICLE_BY_CURRVAL,
    S_ARTICLE_OWNER,
    S_ARTICLE_UPDATE,
    S_ARTICLE_DELETE,
    S_ARTICLE_ID,
    S_FAVORITE,
    S_UNFAVORITE,
    S_COMMENTS_BY_SLUG,
    S_COMMENT_INSERT,
    S_COMMENT_OWNER,
    S_COMMENT_DELETE,
    S_COUNT
};

#define SQL_MAX_PARAMS 6
#define SQL_MAX_COLS 14

struct stmt_def {
    const char *sql;
    uint16_t nparams, ncols;
    uint32_t params[SQL_MAX_PARAMS];
    uint32_t cols[SQL_MAX_COLS];
};

extern const struct stmt_def stmts[S_COUNT];
extern const char *const stmt_names[S_COUNT];

/* Session settings sent once on every connection (rule 2 allows session-level SET). */
extern const char *const session_sql[];
