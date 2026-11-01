#ifndef API_RENDER_H
#define API_RENDER_H

#include <stdbool.h>

#include "core/buf.h"
#include "pg/pg.h"

/* views are copies of column ptrs into one live pg_result, built and rendered
 * in the same callback */

typedef struct user_view {
    const char *username;
    const char *email;
    const char *bio;
    const char *image;
    bool bio_null;
    bool image_null;
} user_view;

typedef struct profile_view {
    const char *username;
    const char *bio;
    const char *image;
    bool bio_null;
    bool image_null;
    bool following;
} profile_view;

typedef struct article_view {
    const char *slug;
    const char *title;
    const char *description;
    const char *body;
    bool body_present;
    long long created_at;           // epoch micros (UTC)
    long long updated_at;
    const char *tags;               // pg text[] literal
    bool tags_null;
    const char *favorites_count;
    bool favorited;
    const char *author_username;
    const char *author_bio;
    const char *author_image;
    bool author_bio_null;
    bool author_image_null;
    bool following;
} article_view;

typedef struct comment_view {
    long long id;
    const char *body;
    long long created_at;           // epoch micros (UTC)
    long long updated_at;
    const char *author_username;
    const char *author_bio;
    const char *author_image;
    bool author_bio_null;
    bool author_image_null;
    bool following;
} comment_view;

void user_view_load(user_view *v, const pg_result *res, int row);
void profile_view_load(profile_view *v, const pg_result *res, int row);
void article_view_load(article_view *v, const pg_result *res, int row,
                       bool full);
void comment_view_load(comment_view *v, const pg_result *res, int row,
                       bool with_following);

void render_user(buf *out, const user_view *v, const char *token);
void render_profile(buf *out, const profile_view *v);
void render_article(buf *out, const article_view *v);
void render_comment(buf *out, const comment_view *v);

// pg text[] literal -> json array
void render_tag_array(buf *out, const char *literal);

#endif
