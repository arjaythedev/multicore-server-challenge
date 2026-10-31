#include "http_routes.h"

static void handle_users_and_profiles(db_conn_t *db, http_req_t *req, http_res_t *res) {
    const char *p = req->path;

    // POST /api/users
    if (req->method == HTTP_METHOD_POST && strcmp(p, "/api/users") == 0) {
        const char *w = find_json_wrapper(req->body, req->body_len, "user");
        if (!w) { res_error(res, 422, "invalid body"); return; }
        char username[128], email[128], password[128];
        bool n1, n2, n3;
        int r1 = get_json_string(w, "username", username, sizeof(username), &n1);
        int r2 = get_json_string(w, "email", email, sizeof(email), &n2);
        int r3 = get_json_string(w, "password", password, sizeof(password), &n3);
        if (r1 != 1 || r2 != 1 || r3 != 1 || n1 || n2 || n3 || !username[0] || !email[0] || !password[0]) {
            res_error(res, 422, "username, email and password are required");
            return;
        }
        if (strlen(password) > 72) {
            res_error(res, 422, "password is too long");
            return;
        }
        char hash[128];
        if (!hash_password(password, hash, sizeof(hash))) {
            res_error(res, 500, "could not hash password");
            return;
        }
        db_register_user(db, username, email, hash, res);
        return;
    }

    // POST /api/users/login
    if (req->method == HTTP_METHOD_POST && strcmp(p, "/api/users/login") == 0) {
        const char *w = find_json_wrapper(req->body, req->body_len, "user");
        if (!w) { res_error(res, 422, "invalid body"); return; }
        char email[128], password[128];
        bool n1, n2;
        int r1 = get_json_string(w, "email", email, sizeof(email), &n1);
        int r2 = get_json_string(w, "password", password, sizeof(password), &n2);
        if (r1 != 1 || r2 != 1 || n1 || n2 || !email[0] || !password[0]) {
            res_error(res, 422, "email and password are required");
            return;
        }
        if (strlen(password) > 72) {
            res_error(res, 401, "invalid email or password");
            return;
        }
        db_login_user(db, email, password, res);
        return;
    }

    // GET /api/user (auth required)
    if (req->method == HTTP_METHOD_GET && strcmp(p, "/api/user") == 0) {
        if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
        db_get_user(db, req->viewer_id, req->token, res);
        return;
    }

    // PUT /api/user (auth required)
    if (req->method == HTTP_METHOD_PUT && strcmp(p, "/api/user") == 0) {
        if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
        const char *w = find_json_wrapper(req->body, req->body_len, "user");
        if (!w) { res_error(res, 422, "invalid body"); return; }
        char email_buf[128], uname_buf[128], pw_buf[128], bio_buf[1024], img_buf[1024];
        bool n1, n2, n3, n4, n5;
        int r1 = get_json_string(w, "email", email_buf, sizeof(email_buf), &n1);
        int r2 = get_json_string(w, "username", uname_buf, sizeof(uname_buf), &n2);
        int r3 = get_json_string(w, "password", pw_buf, sizeof(pw_buf), &n3);
        int r4 = get_json_string(w, "bio", bio_buf, sizeof(bio_buf), &n4);
        int r5 = get_json_string(w, "image", img_buf, sizeof(img_buf), &n5);

        if (r1 < 0 || r2 < 0 || r3 < 0 || r4 < 0 || r5 < 0) { res_error(res, 422, "invalid user fields"); return; }
        if (r1 == 1 && !email_buf[0]) { res_error(res, 422, "email cannot be empty"); return; }
        if (r2 == 1 && !uname_buf[0]) { res_error(res, 422, "username cannot be empty"); return; }
        if (r3 == 1 && !pw_buf[0]) { res_error(res, 422, "password cannot be empty"); return; }

        const char *email = (r1 == 1 && !n1) ? email_buf : NULL;
        const char *username = (r2 == 1 && !n2) ? uname_buf : NULL;
        const char *bio = (r4 == 1 && !n4) ? bio_buf : NULL;
        const char *image = (r5 == 1 && !n5) ? img_buf : NULL;
        char hash_buf[128];
        const char *hash = NULL;
        if (r3 == 1 && !n3) {
            if (strlen(pw_buf) > 72) { res_error(res, 422, "password is too long"); return; }
            if (!hash_password(pw_buf, hash_buf, sizeof(hash_buf))) {
                res_error(res, 500, "could not hash password");
                return;
            }
            hash = hash_buf;
        }
        db_update_user(db, req->viewer_id, email, username, hash, bio, image, req->token, res);
        return;
    }

    // Profiles: /api/profiles/:username[ /follow ]
    if (strncmp(p, "/api/profiles/", 14) == 0) {
        const char *sub = p + 14;
        const char *slash = strchr(sub, '/');
        if (!slash) {
            // GET /api/profiles/:username (auth optional)
            if (req->method != HTTP_METHOD_GET) { res_error(res, 404, "not found"); return; }
            if (req->has_auth_header && req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
            db_get_profile(db, req->viewer_id, sub, res);
            return;
        } else if (strcmp(slash, "/follow") == 0) {
            // POST or DELETE /api/profiles/:username/follow (auth required)
            if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
            char target_uname[128];
            int ulen = (int)(slash - sub);
            if (ulen >= (int)sizeof(target_uname)) ulen = (int)sizeof(target_uname) - 1;
            memcpy(target_uname, sub, ulen);
            target_uname[ulen] = '\0';
            if (req->method == HTTP_METHOD_POST) {
                db_follow(db, req->viewer_id, target_uname, true, res);
                return;
            } else if (req->method == HTTP_METHOD_DELETE) {
                db_follow(db, req->viewer_id, target_uname, false, res);
                return;
            } else {
                res_error(res, 404, "not found");
                return;
            }
        }
    }
    res_error(res, 404, "not found");
}

static void handle_articles_and_comments(db_conn_t *db, http_req_t *req, http_res_t *res) {
    const char *p = req->path;

    // GET /api/articles/feed (auth required)
    if (strcmp(p, "/api/articles/feed") == 0) {
        if (req->method != HTTP_METHOD_GET) { res_error(res, 404, "not found"); return; }
        if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
        int64_t limit = 20, offset = 0;
        char l_buf[32], o_buf[32];
        if (get_query_param(req->query, "limit", l_buf, sizeof(l_buf))) {
            if (!parse_query_uint(l_buf, &limit) || limit < 1 || limit > 100) {
                res_error(res, 422, "invalid limit"); return;
            }
        }
        if (get_query_param(req->query, "offset", o_buf, sizeof(o_buf))) {
            if (!parse_query_uint(o_buf, &offset) || offset < 0) {
                res_error(res, 422, "invalid offset"); return;
            }
        }
        db_feed(db, req->viewer_id, limit, offset, res);
        return;
    }

    // GET or POST /api/articles
    if (strcmp(p, "/api/articles") == 0) {
        if (req->method == HTTP_METHOD_GET) {
            if (req->has_auth_header && req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
            int64_t limit = 20, offset = 0;
            char l_buf[32], o_buf[32];
            if (get_query_param(req->query, "limit", l_buf, sizeof(l_buf))) {
                if (!parse_query_uint(l_buf, &limit) || limit < 1 || limit > 100) {
                    res_error(res, 422, "invalid limit"); return;
                }
            }
            if (get_query_param(req->query, "offset", o_buf, sizeof(o_buf))) {
                if (!parse_query_uint(o_buf, &offset) || offset < 0) {
                    res_error(res, 422, "invalid offset"); return;
                }
            }
            char tag[128], author[128], favorited[128];
            filter_type_t ft = FILTER_NONE;
            const char *fv = NULL;
            if (get_query_param(req->query, "tag", tag, sizeof(tag)) && tag[0]) {
                ft = FILTER_TAG; fv = tag;
            } else if (get_query_param(req->query, "author", author, sizeof(author)) && author[0]) {
                ft = FILTER_AUTHOR; fv = author;
            } else if (get_query_param(req->query, "favorited", favorited, sizeof(favorited)) && favorited[0]) {
                ft = FILTER_FAVORITED; fv = favorited;
            }
            db_list_articles(db, req->viewer_id, limit, offset, ft, fv, res);
            return;
        } else if (req->method == HTTP_METHOD_POST) {
            if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
            const char *w = find_json_wrapper(req->body, req->body_len, "article");
            if (!w) { res_error(res, 422, "invalid body"); return; }
            char title[256], desc[1024], body[32768];
            bool n1, n2, n3;
            int r1 = get_json_string(w, "title", title, sizeof(title), &n1);
            int r2 = get_json_string(w, "description", desc, sizeof(desc), &n2);
            int r3 = get_json_string(w, "body", body, sizeof(body), &n3);
            if (r1 != 1 || r2 != 1 || r3 != 1 || n1 || n2 || n3 || !title[0] || !desc[0] || !body[0]) {
                res_error(res, 422, "title, description and body are required"); return;
            }
            char *tags[64];
            char tag_storage[2048];
            int tag_count = get_json_tag_list(w, tags, tag_storage, sizeof(tag_storage), 64);
            if (tag_count < 0) {
                res_error(res, 422, "invalid tagList"); return;
            }
            tag_count = sort_dedup_tags(tags, tag_count);
            char slug_prefix[256];
            slugify_title(title, strlen(title), slug_prefix);
            db_create_article(db, req->viewer_id, title, slug_prefix, desc, body, tags, tag_count, res);
            return;
        } else {
            res_error(res, 404, "not found");
            return;
        }
    }
    if (strncmp(p, "/api/articles/", 14) == 0) {
        const char *sub = p + 14;
        const char *slash = strchr(sub, '/');
        if (!slash) {
            if (req->method == HTTP_METHOD_GET) {
                if (req->has_auth_header && req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
                db_get_article(db, req->viewer_id, sub, res);
                return;
            } else if (req->method == HTTP_METHOD_PUT) {
                if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
                const char *w = find_json_wrapper(req->body, req->body_len, "article");
                if (!w) { res_error(res, 422, "invalid body"); return; }
                char title_buf[256], desc_buf[1024], body_buf[32768];
                bool n1, n2, n3;
                int r1 = get_json_string(w, "title", title_buf, sizeof(title_buf), &n1);
                int r2 = get_json_string(w, "description", desc_buf, sizeof(desc_buf), &n2);
                int r3 = get_json_string(w, "body", body_buf, sizeof(body_buf), &n3);
                if (r1 < 0 || r2 < 0 || r3 < 0) { res_error(res, 422, "invalid article fields"); return; }
                if (r1 == 1 && !title_buf[0]) { res_error(res, 422, "title cannot be empty"); return; }

                const char *title = (r1 == 1 && !n1) ? title_buf : NULL;
                const char *desc = (r2 == 1 && !n2) ? desc_buf : NULL;
                const char *body = (r3 == 1 && !n3) ? body_buf : NULL;
                char slug_pfx[256];
                const char *pfx_arg = NULL;
                if (title) {
                    slugify_title(title, strlen(title), slug_pfx);
                    pfx_arg = slug_pfx;
                }
                db_update_article(db, req->viewer_id, sub, title, pfx_arg, desc, body, res);
                return;
            } else if (req->method == HTTP_METHOD_DELETE) {
                if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
                db_delete_article(db, req->viewer_id, sub, res);
                return;
            } else {
                res_error(res, 404, "not found");
                return;
            }
        }

        char slug[256];
        int slen = (int)(slash - sub);
        if (slen >= (int)sizeof(slug)) slen = (int)sizeof(slug) - 1;
        memcpy(slug, sub, slen);
        slug[slen] = '\0';

        if (strcmp(slash, "/favorite") == 0) {
            if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
            if (req->method == HTTP_METHOD_POST) {
                db_favorite(db, req->viewer_id, slug, true, res);
                return;
            } else if (req->method == HTTP_METHOD_DELETE) {
                db_favorite(db, req->viewer_id, slug, false, res);
                return;
            } else {
                res_error(res, 404, "not found");
                return;
            }
        }

        if (strcmp(slash, "/comments") == 0) {
            if (req->method == HTTP_METHOD_GET) {
                if (req->has_auth_header && req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
                db_list_comments(db, req->viewer_id, slug, res);
                return;
            } else if (req->method == HTTP_METHOD_POST) {
                if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
                const char *w = find_json_wrapper(req->body, req->body_len, "comment");
                if (!w) { res_error(res, 422, "invalid body"); return; }
                char cbody[4096];
                bool n;
                int r = get_json_string(w, "body", cbody, sizeof(cbody), &n);
                if (r != 1 || n || !cbody[0]) {
                    res_error(res, 422, "body is required"); return;
                }
                db_create_comment(db, req->viewer_id, slug, cbody, res);
                return;
            } else {
                res_error(res, 404, "not found");
                return;
            }
        }

        if (strncmp(slash, "/comments/", 10) == 0) {
            const char *cid_str = slash + 10;
            int64_t cid = 0;
            if (!parse_query_uint(cid_str, &cid) || cid <= 0) {
                res_error(res, 404, "comment not found"); return;
            }
            if (req->method == HTTP_METHOD_DELETE) {
                if (req->viewer_id <= 0) { res_error(res, 401, "unauthorized"); return; }
                db_delete_comment(db, req->viewer_id, slug, cid, res);
                return;
            } else {
                res_error(res, 404, "not found");
                return;
            }
        }
    }

    res_error(res, 404, "not found");
}
void handle_request(db_conn_t *db, http_req_t *req, http_res_t *res) {
    if (req->method == HTTP_METHOD_GET && strcmp(req->path, "/api/tags") == 0) {
        db_list_tags(db, res);
        return;
    }

    if (strncmp(req->path, "/api/user", 9) == 0 || strncmp(req->path, "/api/profiles/", 14) == 0) {
        handle_users_and_profiles(db, req, res);
        return;
    }

    if (strncmp(req->path, "/api/articles", 13) == 0) {
        handle_articles_and_comments(db, req, res);
        return;
    }

    res_error(res, 404, "not found");
}

