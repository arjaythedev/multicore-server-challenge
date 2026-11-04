#ifndef DB_H
#define DB_H

#include "conduit.h"
#include "pg_wire.h"
#include <libpq-fe.h>

typedef struct {
    PGconn *conn;
    pg_wire_conn_t wire;
} db_conn_t;


typedef enum {
    FILTER_NONE = 0,
    FILTER_TAG,
    FILTER_AUTHOR,
    FILTER_FAVORITED
} filter_type_t;

db_conn_t *db_connect(const char *conninfo);
void db_close(db_conn_t *db);
bool db_init_statements(db_conn_t *db);

void db_list_tags(db_conn_t *db, http_res_t *res);

void db_register_user(db_conn_t *db, const char *username, const char *email, const char *hash, http_res_t *res);
void db_login_user(db_conn_t *db, const char *email, const char *password, http_res_t *res);
void db_get_user(db_conn_t *db, int64_t user_id, const char *token, http_res_t *res);
void db_update_user(db_conn_t *db, int64_t user_id, const char *email, const char *username,
                    const char *hash, const char *bio, const char *image, const char *token, http_res_t *res);

void db_get_profile(db_conn_t *db, int64_t viewer, const char *username, http_res_t *res);
void db_follow(db_conn_t *db, int64_t viewer, const char *username, bool follow, http_res_t *res);

void db_list_articles(db_conn_t *db, int64_t viewer, int64_t limit, int64_t offset,
                      filter_type_t filter_type, const char *filter_val, http_res_t *res);
void db_feed(db_conn_t *db, int64_t viewer, int64_t limit, int64_t offset, http_res_t *res);
void db_get_article(db_conn_t *db, int64_t viewer, const char *slug, http_res_t *res);
void db_create_article(db_conn_t *db, int64_t viewer, const char *title, const char *slug_prefix,
                       const char *desc, const char *body, char **tags, int tag_count, http_res_t *res);
void db_update_article(db_conn_t *db, int64_t viewer, const char *slug, const char *title,
                       const char *slug_prefix, const char *desc, const char *body, http_res_t *res);
void db_delete_article(db_conn_t *db, int64_t viewer, const char *slug, http_res_t *res);
void db_favorite(db_conn_t *db, int64_t viewer, const char *slug, bool fav, http_res_t *res);

void db_list_comments(db_conn_t *db, int64_t viewer, const char *slug, http_res_t *res);
void db_create_comment(db_conn_t *db, int64_t viewer, const char *slug, const char *body, http_res_t *res);
void db_delete_comment(db_conn_t *db, int64_t viewer, const char *slug, int64_t comment_id, http_res_t *res);

#endif // DB_H
