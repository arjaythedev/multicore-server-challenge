#ifndef DB_FORMAT_H
#define DB_FORMAT_H

#include "conduit.h"
#include "json_simd.h"
#include <libpq-fe.h>
#include "pg_wire.h"


static inline void format_pg_array_tags(http_res_t *res, const char *raw, int raw_len) {
    if (!raw || raw_len <= 2 || (raw_len == 2 && raw[0] == '{' && raw[1] == '}')) {
        RES_APPEND_LIT(res, "[]");
        return;
    }
    RES_APPEND_LIT(res, "[");
    const char *p = raw;
    const char *end = raw + raw_len;
    if (p < end && *p == '{') p++;
    bool first = true;
    while (p < end && *p != '}') {
        if (*p == ',') {
            p++;
            continue;
        }
        if (!first) RES_APPEND_LIT(res, ",");
        first = false;

        RES_APPEND_LIT(res, "\"");
        if (*p == '"') {
            p++;
            while (p < end && *p != '"') {
                if (*p == '\\' && (p + 1) < end) p++;
                char c[2] = { *p, 0 };
                res_append(res, c, 1);
                p++;
            }
            if (p < end && *p == '"') p++;
        } else {
            const char *start = p;
            while (p < end && *p != ',' && *p != '}') p++;
            res_append(res, start, (int)(p - start));
        }
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, "]");
}

static inline void format_user_json(http_res_t *res, int status,
                                    const char *email, int email_len,
                                    const char *token,
                                    const char *username, int username_len,
                                    const char *bio, int bio_len,
                                    const char *image, int image_len) {
    res->status = status;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"user\":{\"email\":\"");
    if (email && email_len > 0) res_append(res, email, email_len);
    RES_APPEND_LIT(res, "\",\"token\":\"");
    res_append_str(res, token ? token : "");
    RES_APPEND_LIT(res, "\",\"username\":\"");
    if (username && username_len > 0) res_append(res, username, username_len);
    RES_APPEND_LIT(res, "\",\"bio\":");
    if (!bio || bio_len < 0) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, bio, bio_len);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"image\":");
    if (!image || image_len < 0) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, image, image_len);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, "}}");
}

static inline void format_profile_json(http_res_t *res,
                                       const char *username, int username_len,
                                       const char *bio, int bio_len,
                                       const char *image, int image_len,
                                       bool following) {
    res->status = 200;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"profile\":{\"username\":\"");
    if (username && username_len > 0) res_append(res, username, username_len);
    RES_APPEND_LIT(res, "\",\"bio\":");
    if (!bio || bio_len < 0) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, bio, bio_len);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"image\":");
    if (!image || image_len < 0) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, image, image_len);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"following\":");
    res_append_str(res, following ? "true" : "false");
    RES_APPEND_LIT(res, "}}");
}
static inline void format_article_row(http_res_t *res, PGresult *pg_res, int row, bool with_body) {
    const char *slug = PQgetvalue(pg_res, row, 1);
    const char *title = PQgetvalue(pg_res, row, 2);
    const char *desc = PQgetvalue(pg_res, row, 3);
    int col_offset = 0;
    const char *body = NULL;
    if (with_body) {
        body = PQgetvalue(pg_res, row, 4);
        col_offset = 1;
    }
    const char *created_raw = PQgetvalue(pg_res, row, 4 + col_offset);
    const char *updated_raw = PQgetvalue(pg_res, row, 5 + col_offset);
    const char *tags_raw = PQgetvalue(pg_res, row, 6 + col_offset);
    const char *fav_cnt = PQgetvalue(pg_res, row, 7 + col_offset);
    bool favorited = (PQgetvalue(pg_res, row, 8 + col_offset)[0] == 't');
    const char *author_uname = PQgetvalue(pg_res, row, 9 + col_offset);
    const char *author_bio = PQgetisnull(pg_res, row, 10 + col_offset) ? NULL : PQgetvalue(pg_res, row, 10 + col_offset);
    const char *author_img = PQgetisnull(pg_res, row, 11 + col_offset) ? NULL : PQgetvalue(pg_res, row, 11 + col_offset);
    bool following = (PQgetvalue(pg_res, row, 12 + col_offset)[0] == 't');

    char ts_created[32], ts_updated[32];
    pg_text_to_rfc3339(created_raw, PQgetlength(pg_res, row, 4 + col_offset), ts_created);
    pg_text_to_rfc3339(updated_raw, PQgetlength(pg_res, row, 5 + col_offset), ts_updated);

    RES_APPEND_LIT(res, "{\"slug\":\"");
    res_append_str(res, slug);
    RES_APPEND_LIT(res, "\",\"title\":\"");
    res_append_escaped(res, title, PQgetlength(pg_res, row, 2));
    RES_APPEND_LIT(res, "\",\"description\":\"");
    res_append_escaped(res, desc, PQgetlength(pg_res, row, 3));
    if (with_body && body) {
        RES_APPEND_LIT(res, "\",\"body\":\"");
        res_append_escaped(res, body, PQgetlength(pg_res, row, 4));
    }
    RES_APPEND_LIT(res, "\",\"tagList\":");
    format_pg_array_tags(res, tags_raw, PQgetlength(pg_res, row, 6 + col_offset));
    RES_APPEND_LIT(res, ",\"createdAt\":\"");
    res_append_str(res, ts_created);
    RES_APPEND_LIT(res, "\",\"updatedAt\":\"");
    res_append_str(res, ts_updated);
    RES_APPEND_LIT(res, "\",\"favorited\":");
    res_append_str(res, favorited ? "true" : "false");
    RES_APPEND_LIT(res, ",\"favoritesCount\":");
    res_append_str(res, (fav_cnt && fav_cnt[0]) ? fav_cnt : "0");
    RES_APPEND_LIT(res, ",\"author\":{\"username\":\"");
    res_append_str(res, author_uname);
    RES_APPEND_LIT(res, "\",\"bio\":");
    if (!author_bio) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, author_bio, PQgetlength(pg_res, row, 10 + col_offset));
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"image\":");
    if (!author_img) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, author_img, PQgetlength(pg_res, row, 11 + col_offset));
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"following\":");
    res_append_str(res, following ? "true" : "false");
    RES_APPEND_LIT(res, "}}");
}

static inline void format_comment_row(http_res_t *res, PGresult *pg_res, int row) {
    const char *id = PQgetvalue(pg_res, row, 0);
    const char *body = PQgetvalue(pg_res, row, 1);
    const char *created_raw = PQgetvalue(pg_res, row, 2);
    const char *updated_raw = PQgetvalue(pg_res, row, 3);
    const char *author_uname = PQgetvalue(pg_res, row, 4);
    const char *author_bio = PQgetisnull(pg_res, row, 5) ? NULL : PQgetvalue(pg_res, row, 5);
    const char *author_img = PQgetisnull(pg_res, row, 6) ? NULL : PQgetvalue(pg_res, row, 6);
    bool following = false;
    if (PQnfields(pg_res) > 7) {
        following = (PQgetvalue(pg_res, row, 7)[0] == 't');
    }

    char ts_created[32], ts_updated[32];
    pg_text_to_rfc3339(created_raw, PQgetlength(pg_res, row, 2), ts_created);
    pg_text_to_rfc3339(updated_raw, PQgetlength(pg_res, row, 3), ts_updated);

    RES_APPEND_LIT(res, "{\"id\":");
    res_append_str(res, id);
    RES_APPEND_LIT(res, ",\"createdAt\":\"");
    res_append_str(res, ts_created);
    RES_APPEND_LIT(res, "\",\"updatedAt\":\"");
    res_append_str(res, ts_updated);
    RES_APPEND_LIT(res, "\",\"body\":\"");
    res_append_escaped(res, body, PQgetlength(pg_res, row, 1));
    RES_APPEND_LIT(res, "\",\"author\":{\"username\":\"");
    res_append_str(res, author_uname);
    RES_APPEND_LIT(res, "\",\"bio\":");
    if (!author_bio) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, author_bio, PQgetlength(pg_res, row, 5));
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"image\":");
    if (!author_img) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, author_img, PQgetlength(pg_res, row, 6));
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"following\":");
    res_append_str(res, following ? "true" : "false");
    RES_APPEND_LIT(res, "}}");
}
static inline void format_article_row_wire(http_res_t *res, const pg_row_t *r, bool with_body) {
    const char *slug = r->col_vals[1];
    int slug_len = r->col_lens[1];
    const char *title = r->col_vals[2];
    int title_len = r->col_lens[2];
    const char *desc = r->col_vals[3];
    int desc_len = r->col_lens[3];
    int col_offset = 0;
    const char *body = NULL;
    int body_len = 0;
    if (with_body) {
        body = r->col_vals[4];
        body_len = r->col_lens[4];
        col_offset = 1;
    }
    const char *created_raw = r->col_vals[4 + col_offset];
    const char *updated_raw = r->col_vals[5 + col_offset];
    const char *tags_raw = r->col_vals[6 + col_offset];
    int tags_len = r->col_lens[6 + col_offset];
    const char *fav_cnt = r->col_vals[7 + col_offset];
    int fav_cnt_len = r->col_lens[7 + col_offset];
    bool favorited = (r->col_vals[8 + col_offset] && r->col_vals[8 + col_offset][0] == 't');
    const char *author_uname = r->col_vals[9 + col_offset];
    int author_uname_len = r->col_lens[9 + col_offset];
    const char *author_bio = r->col_vals[10 + col_offset];
    int author_bio_len = r->col_lens[10 + col_offset];

    const char *author_img = r->col_vals[11 + col_offset];
    int author_img_len = r->col_lens[11 + col_offset];
    bool following = (r->col_vals[12 + col_offset] && r->col_vals[12 + col_offset][0] == 't');

    char ts_created[32], ts_updated[32];
    pg_text_to_rfc3339(created_raw, r->col_lens[4 + col_offset], ts_created);
    pg_text_to_rfc3339(updated_raw, r->col_lens[5 + col_offset], ts_updated);

    RES_APPEND_LIT(res, "{\"slug\":\"");
    res_append(res, slug, slug_len);
    RES_APPEND_LIT(res, "\",\"title\":\"");
    res_append_escaped(res, title, title_len);
    RES_APPEND_LIT(res, "\",\"description\":\"");
    res_append_escaped(res, desc, desc_len);
    if (with_body && body) {
        RES_APPEND_LIT(res, "\",\"body\":\"");
        res_append_escaped(res, body, body_len);
    }
    RES_APPEND_LIT(res, "\",\"tagList\":");
    format_pg_array_tags(res, tags_raw, tags_len);
    RES_APPEND_LIT(res, ",\"createdAt\":\"");
    res_append_str(res, ts_created);
    RES_APPEND_LIT(res, "\",\"updatedAt\":\"");
    res_append_str(res, ts_updated);
    RES_APPEND_LIT(res, "\",\"favorited\":");
    res_append_str(res, favorited ? "true" : "false");
    RES_APPEND_LIT(res, ",\"favoritesCount\":");
    if (fav_cnt && fav_cnt_len > 0) res_append(res, fav_cnt, fav_cnt_len);
    else RES_APPEND_LIT(res, "0");
    RES_APPEND_LIT(res, ",\"author\":{\"username\":\"");
    res_append(res, author_uname, author_uname_len);
    RES_APPEND_LIT(res, "\",\"bio\":");
    if (!author_bio) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, author_bio, author_bio_len);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"image\":");
    if (!author_img) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, author_img, author_img_len);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"following\":");
    res_append_str(res, following ? "true" : "false");
    RES_APPEND_LIT(res, "}}");
}

static inline void format_comment_row_wire(http_res_t *res, const pg_row_t *r) {
    const char *id = r->col_vals[0];
    int id_len = r->col_lens[0];
    const char *body = r->col_vals[1];
    int body_len = r->col_lens[1];
    const char *created_raw = r->col_vals[2];
    const char *updated_raw = r->col_vals[3];
    const char *author_uname = r->col_vals[4];
    int author_uname_len = r->col_lens[4];
    const char *author_bio = r->col_vals[5];
    int author_bio_len = r->col_lens[5];
    const char *author_img = r->col_vals[6];
    int author_img_len = r->col_lens[6];
    bool following = false;
    if (r->col_count > 7 && r->col_vals[7]) {
        following = (r->col_vals[7][0] == 't');
    }

    char ts_created[32], ts_updated[32];
    pg_text_to_rfc3339(created_raw, r->col_lens[2], ts_created);
    pg_text_to_rfc3339(updated_raw, r->col_lens[3], ts_updated);

    RES_APPEND_LIT(res, "{\"id\":");
    res_append(res, id, id_len);
    RES_APPEND_LIT(res, ",\"createdAt\":\"");
    res_append_str(res, ts_created);
    RES_APPEND_LIT(res, "\",\"updatedAt\":\"");
    res_append_str(res, ts_updated);
    RES_APPEND_LIT(res, "\",\"body\":\"");
    res_append_escaped(res, body, body_len);
    RES_APPEND_LIT(res, "\",\"author\":{\"username\":\"");
    res_append(res, author_uname, author_uname_len);
    RES_APPEND_LIT(res, "\",\"bio\":");
    if (!author_bio) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, author_bio, author_bio_len);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"image\":");
    if (!author_img) {
        RES_APPEND_LIT(res, "null");
    } else {
        RES_APPEND_LIT(res, "\"");
        res_append_escaped(res, author_img, author_img_len);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, ",\"following\":");
    res_append_str(res, following ? "true" : "false");
    RES_APPEND_LIT(res, "}}");
}



#endif // DB_FORMAT_H
