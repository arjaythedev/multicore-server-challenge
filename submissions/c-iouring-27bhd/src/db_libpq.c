#include "db.h"
#include "sql_queries.h"
#include "db_format.h"
#include "auth_crypto.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>



db_conn_t *db_connect(const char *conninfo) {
    char conn_str[1024];
    if (strstr(conninfo, "sslmode=")) {
        strncpy(conn_str, conninfo, sizeof(conn_str) - 1);
    } else if (strncmp(conninfo, "postgres://", 11) == 0 || strncmp(conninfo, "postgresql://", 13) == 0) {
        if (strchr(conninfo, '?')) {
            snprintf(conn_str, sizeof(conn_str), "%s&sslmode=disable", conninfo);
        } else {
            snprintf(conn_str, sizeof(conn_str), "%s?sslmode=disable", conninfo);
        }
    } else {
        snprintf(conn_str, sizeof(conn_str), "%s sslmode=disable", conninfo);
    }

    PGconn *conn = PQconnectdb(conn_str);
    if (PQstatus(conn) != CONNECTION_OK) {
        fprintf(stderr, "Connection to database failed: %s\n", PQerrorMessage(conn));
        PQfinish(conn);
        return NULL;
    }
    int pg_fd = PQsocket(conn);
    if (pg_fd >= 0) {
        int one = 1;
        setsockopt(pg_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setsockopt(pg_fd, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one));
        int sndbuf = 262144;
        setsockopt(pg_fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        int rcvbuf = 524288;
        setsockopt(pg_fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    }
    PGresult *res = PQexec(conn, "SET jit = off; SET plan_cache_mode = force_generic_plan; SET TimeZone = 'UTC';");
    if (PQresultStatus(res) != PGRES_COMMAND_OK) {
        fprintf(stderr, "Failed to set session params: %s\n", PQerrorMessage(conn));
    }
    PQclear(res);

    db_conn_t *db = (db_conn_t *)malloc(sizeof(db_conn_t));
    db->conn = conn;
    pg_wire_init_conn(&db->wire, pg_fd);
    if (!db_init_statements(db)) {
        fprintf(stderr, "Failed to prepare statements\n");
    }
    return db;
}

void db_close(db_conn_t *db) {
    if (db) {
        if (db->conn) PQfinish(db->conn);
        free(db);
    }
}

static bool prep(PGconn *conn, const char *stmtName, const char *query) {
    PGresult *res = PQprepare(conn, stmtName, query, 0, NULL);
    ExecStatusType st = PQresultStatus(res);
    if (st != PGRES_COMMAND_OK) {
        fprintf(stderr, "Prepare %s failed: %s\n", stmtName, PQerrorMessage(conn));
        PQclear(res);
        return false;
    }
    PQclear(res);
    return true;
}

bool db_init_statements(db_conn_t *db) {
    PGconn *c = db->conn;
    bool ok = true;
    ok &= prep(c, "list_tags", SQL_LIST_TAGS);
    ok &= prep(c, "reg_user", SQL_REGISTER_USER);
    ok &= prep(c, "login_user", SQL_LOGIN_USER);
    ok &= prep(c, "get_user", SQL_GET_USER);
    ok &= prep(c, "update_user", SQL_UPDATE_USER);
    ok &= prep(c, "get_profile", SQL_GET_PROFILE);
    ok &= prep(c, "follow_u", SQL_FOLLOW_BY_USERNAME);
    ok &= prep(c, "unfollow_u", SQL_UNFOLLOW_BY_USERNAME);

    ok &= prep(c, "list_all", SQL_LIST_ALL);
    ok &= prep(c, "count_all", SQL_COUNT_ALL);
    ok &= prep(c, "list_by_tag", SQL_LIST_BY_TAG);
    ok &= prep(c, "count_by_tag", SQL_COUNT_BY_TAG);
    ok &= prep(c, "list_by_auth", SQL_LIST_BY_AUTHOR);
    ok &= prep(c, "count_by_auth", SQL_COUNT_BY_AUTHOR);
    ok &= prep(c, "list_by_fav", SQL_LIST_BY_FAVORITE);
    ok &= prep(c, "count_by_fav", SQL_COUNT_BY_FAVORITE);
    ok &= prep(c, "list_feed", SQL_LIST_FEED);
    ok &= prep(c, "count_feed", SQL_COUNT_FEED);

    ok &= prep(c, "list_all_10_0", SQL_LIST_ALL_10_0);
    ok &= prep(c, "list_all_5_0", SQL_LIST_ALL_5_0);
    ok &= prep(c, "list_all_20_0", SQL_LIST_ALL_20_0);
    ok &= prep(c, "list_tag_10_0", SQL_LIST_TAG_10_0);
    ok &= prep(c, "list_tag_5_0", SQL_LIST_TAG_5_0);
    ok &= prep(c, "list_tag_20_0", SQL_LIST_TAG_20_0);
    ok &= prep(c, "list_auth_10_0", SQL_LIST_AUTH_10_0);
    ok &= prep(c, "list_auth_5_0", SQL_LIST_AUTH_5_0);
    ok &= prep(c, "list_auth_20_0", SQL_LIST_AUTH_20_0);
    ok &= prep(c, "list_fav_10_0", SQL_LIST_FAV_10_0);
    ok &= prep(c, "list_fav_5_0", SQL_LIST_FAV_5_0);
    ok &= prep(c, "list_fav_20_0", SQL_LIST_FAV_20_0);
    ok &= prep(c, "list_feed_10_0", SQL_LIST_FEED_10_0);
    ok &= prep(c, "list_feed_5_0", SQL_LIST_FEED_5_0);
    ok &= prep(c, "list_feed_20_0", SQL_LIST_FEED_20_0);

    ok &= prep(c, "art_by_slug", SQL_ARTICLE_BY_SLUG);
    ok &= prep(c, "ins_art", SQL_INSERT_ARTICLE);
    ok &= prep(c, "ins_tags", SQL_INSERT_TAGS);
    ok &= prep(c, "ins_art_tags_currval", SQL_INSERT_ARTICLE_TAGS_CURRVAL);
    ok &= prep(c, "art_by_currval", SQL_ARTICLE_BY_CURRVAL);
    ok &= prep(c, "upd_art_fused", SQL_UPDATE_ARTICLE_FUSED);
    ok &= prep(c, "del_art_cte", SQL_DELETE_ARTICLE_CTE);

    ok &= prep(c, "fav_ins_slug", SQL_FAVORITE_INSERT_BY_SLUG);
    ok &= prep(c, "fav_del_slug", SQL_FAVORITE_DELETE_BY_SLUG);
    ok &= prep(c, "sel_art_id", SQL_SELECT_ARTICLE_ID);
    ok &= prep(c, "list_comm_slug", SQL_LIST_COMMENTS_BY_SLUG);
    ok &= prep(c, "ins_comment_slug", SQL_INSERT_COMMENT_BY_SLUG);
    ok &= prep(c, "del_comment_cte", SQL_DELETE_COMMENT_CTE);

    return ok;
}

void db_list_tags(db_conn_t *db, http_res_t *res) {
    pg_row_t rows[256];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "list_tags", 0, NULL, rows, 256, &count, NULL)) {
        res_error(res, 500, "database error");
        return;
    }
    res->status = 200;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"tags\":[");
    for (int i = 0; i < count; i++) {
        if (i > 0) RES_APPEND_LIT(res, ",");
        RES_APPEND_LIT(res, "\"");
        res_append(res, rows[i].col_vals[0], rows[i].col_lens[0]);
        RES_APPEND_LIT(res, "\"");
    }
    RES_APPEND_LIT(res, "]}");
}

void db_register_user(db_conn_t *db, const char *username, const char *email, const char *hash, http_res_t *res) {
    const char *params[3] = { username, email, hash };
    pg_row_t rows[1];
    int count = 0;
    char sqlstate[8];
    if (!pg_wire_exec_query(&db->wire, "reg_user", 3, params, rows, 1, &count, sqlstate)) {
        res_error(res, 500, "database error");
        return;
    }
    if (count == 0 || (sqlstate[0] && strcmp(sqlstate, "23505") == 0)) {
        res_error(res, 422, "username or email already taken");
        return;
    }
    int64_t id = strtoll(rows[0].col_vals[0], NULL, 10);
    char token[512];
    jwt_issue(id, token);
    format_user_json(res, 201,
                     rows[0].col_vals[2], rows[0].col_lens[2],
                     token,
                     rows[0].col_vals[1], rows[0].col_lens[1],
                     rows[0].col_vals[3], rows[0].col_lens[3],
                     rows[0].col_vals[4], rows[0].col_lens[4]);
}

void db_login_user(db_conn_t *db, const char *email, const char *password, http_res_t *res) {
    const char *params[1] = { email };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "login_user", 1, params, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 401, "invalid email or password");
        return;
    }
    char stored_hash[128];
    int hlen = rows[0].col_lens[5];
    if (hlen >= (int)sizeof(stored_hash)) hlen = sizeof(stored_hash) - 1;
    memcpy(stored_hash, rows[0].col_vals[5], hlen);
    stored_hash[hlen] = '\0';

    if (!verify_password(password, stored_hash)) {
        res_error(res, 401, "invalid email or password");
        return;
    }
    int64_t id = strtoll(rows[0].col_vals[0], NULL, 10);
    char token[512];
    jwt_issue(id, token);
    format_user_json(res, 200,
                     rows[0].col_vals[2], rows[0].col_lens[2],
                     token,
                     rows[0].col_vals[1], rows[0].col_lens[1],
                     rows[0].col_vals[3], rows[0].col_lens[3],
                     rows[0].col_vals[4], rows[0].col_lens[4]);
}

void db_get_user(db_conn_t *db, int64_t user_id, const char *token, http_res_t *res) {
    char id_str[24];
    u64_to_str((uint64_t)user_id, id_str);
    const char *params[1] = { id_str };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "get_user", 1, params, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 401, "unauthorized");
        return;
    }
    format_user_json(res, 200,
                     rows[0].col_vals[2], rows[0].col_lens[2],
                     token,
                     rows[0].col_vals[1], rows[0].col_lens[1],
                     rows[0].col_vals[3], rows[0].col_lens[3],
                     rows[0].col_vals[4], rows[0].col_lens[4]);
}

void db_update_user(db_conn_t *db, int64_t user_id, const char *email, const char *username,
                    const char *hash, const char *bio, const char *image, const char *token, http_res_t *res) {
    char id_str[24];
    u64_to_str((uint64_t)user_id, id_str);
    const char *params[6] = { id_str, email, username, hash, bio, image };
    pg_row_t rows[1];
    int count = 0;
    char sqlstate[8];
    if (!pg_wire_exec_query(&db->wire, "update_user", 6, params, rows, 1, &count, sqlstate)) {
        if (sqlstate[0] && strcmp(sqlstate, "23505") == 0) {
            res_error(res, 422, "username or email already taken");
        } else {
            res_error(res, 500, "database error");
        }
        return;
    }
    if (sqlstate[0] && strcmp(sqlstate, "23505") == 0) {
        res_error(res, 422, "username or email already taken");
        return;
    }
    if (count == 0) {
        res_error(res, 401, "unauthorized");
        return;
    }
    format_user_json(res, 200,
                     rows[0].col_vals[2], rows[0].col_lens[2],
                     token,
                     rows[0].col_vals[1], rows[0].col_lens[1],
                     rows[0].col_vals[3], rows[0].col_lens[3],
                     rows[0].col_vals[4], rows[0].col_lens[4]);
}

void db_get_profile(db_conn_t *db, int64_t viewer, const char *username, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *params[2] = { v_str, username };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "get_profile", 2, params, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 404, "profile not found");
        return;
    }
    bool following = (rows[0].col_vals[4] && rows[0].col_vals[4][0] == 't');
    format_profile_json(res,
                        rows[0].col_vals[1], rows[0].col_lens[1],
                        rows[0].col_vals[2], rows[0].col_lens[2],
                        rows[0].col_vals[3], rows[0].col_lens[3],
                        following);
}

void db_follow(db_conn_t *db, int64_t viewer, const char *username, bool follow, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *p[2] = { v_str, username };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, follow ? "follow_u" : "unfollow_u", 2, p, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 404, "profile not found");
        return;
    }
    format_profile_json(res,
                        rows[0].col_vals[0], rows[0].col_lens[0],
                        rows[0].col_vals[1], rows[0].col_lens[1],
                        rows[0].col_vals[2], rows[0].col_lens[2],
                        follow);
}

void db_list_articles(db_conn_t *db, int64_t viewer, int64_t limit, int64_t offset,
                      filter_type_t filter_type, const char *filter_val, http_res_t *res) {
    char v_str[24], l_str[24], o_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    u64_to_str((uint64_t)limit, l_str);
    u64_to_str((uint64_t)offset, o_str);

    const char *list_stmt = "list_all";
    const char *count_stmt = "count_all";
    const char *list_params[4];
    int n_list_params = 3;
    const char *count_params[1];
    int n_count_params = 0;

    list_params[0] = v_str;
    list_params[1] = l_str;
    list_params[2] = o_str;

    if (offset == 0 && (limit == 10 || limit == 5 || limit == 20)) {
        if (filter_type == FILTER_NONE) {
            count_stmt = "count_all";
            n_count_params = 0;
            n_list_params = 1;
            if (limit == 10) list_stmt = "list_all_10_0";
            else if (limit == 5) list_stmt = "list_all_5_0";
            else list_stmt = "list_all_20_0";
        } else if (filter_type == FILTER_TAG) {
            count_stmt = "count_by_tag";
            count_params[0] = filter_val;
            n_count_params = 1;
            list_params[1] = filter_val;
            n_list_params = 2;
            if (limit == 10) list_stmt = "list_tag_10_0";
            else if (limit == 5) list_stmt = "list_tag_5_0";
            else list_stmt = "list_tag_20_0";
        } else if (filter_type == FILTER_AUTHOR) {
            count_stmt = "count_by_auth";
            count_params[0] = filter_val;
            n_count_params = 1;
            list_params[1] = filter_val;
            n_list_params = 2;
            if (limit == 10) list_stmt = "list_auth_10_0";
            else if (limit == 5) list_stmt = "list_auth_5_0";
            else list_stmt = "list_auth_20_0";
        } else if (filter_type == FILTER_FAVORITED) {
            count_stmt = "count_by_fav";
            count_params[0] = filter_val;
            n_count_params = 1;
            list_params[1] = filter_val;
            n_list_params = 2;
            if (limit == 10) list_stmt = "list_fav_10_0";
            else if (limit == 5) list_stmt = "list_fav_5_0";
            else list_stmt = "list_fav_20_0";
        }
    } else {
        if (filter_type == FILTER_TAG) {
            list_stmt = "list_by_tag";
            count_stmt = "count_by_tag";
            list_params[3] = filter_val;
            n_list_params = 4;
            count_params[0] = filter_val;
            n_count_params = 1;
        } else if (filter_type == FILTER_AUTHOR) {
            list_stmt = "list_by_auth";
            count_stmt = "count_by_auth";
            list_params[3] = filter_val;
            n_list_params = 4;
            count_params[0] = filter_val;
            n_count_params = 1;
        } else if (filter_type == FILTER_FAVORITED) {
            list_stmt = "list_by_fav";
            count_stmt = "count_by_fav";
            list_params[3] = filter_val;
            n_list_params = 4;
            count_params[0] = filter_val;
            n_count_params = 1;
        }
    }

    pg_wire_conn_t *w = &db->wire;
    pg_append_bind(w, "", list_stmt, n_list_params, list_params, NULL);
    pg_append_exec(w, "", 0);
    pg_append_bind(w, "", count_stmt, n_count_params, count_params, NULL);
    pg_append_exec(w, "", 0);
    pg_append_sync(w);

    if (!pg_flush_sync(w)) {
        res_error(res, 500, "database error");
        return;
    }

    res->status = 200;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"articles\":[");

    int stmt_idx = 0;
    int row_count = 0;
    char total_count_str[32] = "0";
    char type;
    uint32_t len;
    const uint8_t *payload;

    while (1) {
        while (!pg_read_frame(w, &type, &len, &payload)) {
            ssize_t n = recv(w->fd, w->rx_buf + w->rx_len, sizeof(w->rx_buf) - w->rx_len, 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    struct pollfd pfd = { .fd = w->fd, .events = POLLIN };
                    poll(&pfd, 1, 1000);
                    continue;
                }
                res_error(res, 500, "database error");
                return;
            } else if (n == 0) {
                res_error(res, 500, "database error");
                return;
            }
            w->rx_len += (int)n;
        }

        if (type == 'D') {
            pg_row_t row;
            pg_parse_row(payload, len - 4, &row);
            if (stmt_idx == 0) {
                if (row_count > 0) RES_APPEND_LIT(res, ",");
                format_article_row_wire(res, &row, false);
                row_count++;
            } else if (stmt_idx == 1 && row.col_count > 0 && row.col_vals[0]) {
                int clen = row.col_lens[0];
                if (clen >= (int)sizeof(total_count_str)) clen = (int)sizeof(total_count_str) - 1;
                memcpy(total_count_str, row.col_vals[0], clen);
                total_count_str[clen] = '\0';
            }
        } else if (type == 'C') {
            stmt_idx++;
        } else if (type == 'E') {
            res_error(res, 500, "database error");
        } else if (type == 'Z') {
            pg_consume_frame(w, 1 + len);
            break;
        }

        pg_consume_frame(w, 1 + len);
    }

    RES_APPEND_LIT(res, "],\"articlesCount\":");
    res_append_str(res, total_count_str);
    RES_APPEND_LIT(res, "}");
}

void db_feed(db_conn_t *db, int64_t viewer, int64_t limit, int64_t offset, http_res_t *res) {
    char v_str[24], l_str[24], o_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    u64_to_str((uint64_t)limit, l_str);
    u64_to_str((uint64_t)offset, o_str);

    const char *list_stmt = "list_feed";
    const char *list_params[3];
    int n_list_params = 3;
    list_params[0] = v_str;
    list_params[1] = l_str;
    list_params[2] = o_str;

    if (offset == 0) {
        if (limit == 10) { list_stmt = "list_feed_10_0"; n_list_params = 1; }
        else if (limit == 5) { list_stmt = "list_feed_5_0"; n_list_params = 1; }
        else if (limit == 20) { list_stmt = "list_feed_20_0"; n_list_params = 1; }
    }

    pg_wire_conn_t *w = &db->wire;
    pg_compact_rx(w);
    pg_append_bind(w, "", list_stmt, n_list_params, list_params, NULL);
    pg_append_exec(w, "", 0);
    pg_append_sync(w);

    if (!pg_flush_sync(w)) {
        res_error(res, 500, "database error");
        return;
    }

    res->status = 200;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"articles\":[");

    int rows = 0;
    char type;
    uint32_t len;
    const uint8_t *payload;

    while (1) {
        while (!pg_read_frame(w, &type, &len, &payload)) {
            pg_compact_rx(w);
            ssize_t n = recv(w->fd, w->rx_buf + w->rx_len, sizeof(w->rx_buf) - w->rx_len, 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    struct pollfd pfd = { .fd = w->fd, .events = POLLIN };
                    poll(&pfd, 1, 1000);
                    continue;
                }
                res_error(res, 500, "database error");
                return;
            } else if (n == 0) {
                res_error(res, 500, "database error");
                return;
            }
            w->rx_len += (int)n;
        }

        if (type == 'D') {
            pg_row_t row;
            pg_parse_row(payload, len - 4, &row);
            if (rows > 0) RES_APPEND_LIT(res, ",");
            format_article_row_wire(res, &row, false);
            rows++;
        } else if (type == 'E') {
            res_error(res, 500, "database error");
        } else if (type == 'Z') {
            pg_consume_frame(w, 1 + len);
            break;
        }

        pg_consume_frame(w, 1 + len);
    }

    int64_t total_count = 0;
    if (offset == 0 && rows < limit) {
        total_count = rows;
    } else {
        const char *cnt_params[1] = { v_str };
        pg_row_t crow[1];
        int c_count = 0;
        if (pg_wire_exec_query(w, "count_feed", 1, cnt_params, crow, 1, &c_count, NULL) && c_count > 0) {
            total_count = strtoll(crow[0].col_vals[0], NULL, 10);
        }
    }

    RES_APPEND_LIT(res, "],\"articlesCount\":");
    char c_str[24];
    u64_to_str((uint64_t)total_count, c_str);
    res_append_str(res, c_str);
    RES_APPEND_LIT(res, "}");
}

void db_get_article(db_conn_t *db, int64_t viewer, const char *slug, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *params[2] = { v_str, slug };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "art_by_slug", 2, params, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 404, "article not found");
        return;
    }
    res->status = 200;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"article\":");
    format_article_row_wire(res, &rows[0], true);
    RES_APPEND_LIT(res, "}");
}

void db_create_article(db_conn_t *db, int64_t viewer, const char *title, const char *slug_prefix,
                       const char *desc, const char *body, char **tags, int tag_count, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *art_params[5] = { v_str, title, desc, body, slug_prefix };

    pg_wire_conn_t *w = &db->wire;
    pg_compact_rx(w);

    pg_append_bind(w, "", "ins_art", 5, art_params, NULL);
    pg_append_exec(w, "", 0);

    if (tag_count > 0) {
        char pg_arr[4096];
        int aw = snprintf(pg_arr, sizeof(pg_arr), "{");
        for (int i = 0; i < tag_count; i++) {
            if (i > 0) pg_arr[aw++] = ',';
            pg_arr[aw++] = '"';
            int tlen = (int)strlen(tags[i]);
            for (int j = 0; j < tlen; j++) {
                if (tags[i][j] == '"' || tags[i][j] == '\\') pg_arr[aw++] = '\\';
                pg_arr[aw++] = tags[i][j];
            }
            pg_arr[aw++] = '"';
        }
        pg_arr[aw++] = '}';
        pg_arr[aw] = '\0';

        const char *tp[1] = { pg_arr };
        pg_append_bind(w, "", "ins_tags", 1, tp, NULL);
        pg_append_exec(w, "", 0);

        const char *atp[1] = { pg_arr };
        pg_append_bind(w, "", "ins_art_tags_currval", 1, atp, NULL);
        pg_append_exec(w, "", 0);
    }

    const char *sel_params[1] = { v_str };
    pg_append_bind(w, "", "art_by_currval", 1, sel_params, NULL);
    pg_append_exec(w, "", 0);

    pg_append_sync(w);

    if (!pg_flush_sync(w)) {
        res_error(res, 500, "database error");
        return;
    }

    pg_row_t full_row;
    bool has_full = false;
    char type;
    uint32_t len;
    const uint8_t *payload;

    while (1) {
        while (!pg_read_frame(w, &type, &len, &payload)) {
            pg_compact_rx(w);
            ssize_t n = recv(w->fd, w->rx_buf + w->rx_len, sizeof(w->rx_buf) - w->rx_len, 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    struct pollfd pfd = { .fd = w->fd, .events = POLLIN };
                    poll(&pfd, 1, 1000);
                    continue;
                }
                res_error(res, 500, "database error");
                return;
            } else if (n == 0) {
                res_error(res, 500, "database error");
                return;
            }
            w->rx_len += (int)n;
        }

        if (type == 'D') {
            pg_parse_row(payload, len - 4, &full_row);
            has_full = true;
        } else if (type == 'E') {
            res_error(res, 500, "database error");
        } else if (type == 'Z') {
            pg_consume_frame(w, 1 + len);
            break;
        }

        pg_consume_frame(w, 1 + len);
    }

    if (!has_full) {
        res_error(res, 500, "could not create article");
        return;
    }
    res->status = 201;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"article\":");
    format_article_row_wire(res, &full_row, true);
    RES_APPEND_LIT(res, "}");
}
void db_update_article(db_conn_t *db, int64_t viewer, const char *slug, const char *title,
                       const char *slug_prefix, const char *desc, const char *body, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *params[6] = { slug, v_str, title, desc, body, slug_prefix };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "upd_art_fused", 6, params, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 404, "article not found");
        return;
    }
    if (!rows[0].col_vals[1]) {
        res_error(res, 403, "not the author");
        return;
    }
    res->status = 200;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"article\":");
    format_article_row_wire(res, &rows[0], true);
    RES_APPEND_LIT(res, "}");
}

void db_delete_article(db_conn_t *db, int64_t viewer, const char *slug, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *del_p[2] = { slug, v_str };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "del_art_cte", 2, del_p, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 404, "article not found");
        return;
    }
    int64_t author_id = strtoll(rows[0].col_vals[0], NULL, 10);
    if (author_id != viewer) {
        res_error(res, 403, "not the author");
        return;
    }
    res->status = 204;
    res->len = 0;
}

void db_favorite(db_conn_t *db, int64_t viewer, const char *slug, bool fav, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *p[2] = { v_str, slug };

    pg_wire_conn_t *w = &db->wire;
    pg_append_bind(w, "", fav ? "fav_ins_slug" : "fav_del_slug", 2, p, NULL);
    pg_append_exec(w, "", 0);
    pg_append_bind(w, "", "art_by_slug", 2, p, NULL);
    pg_append_exec(w, "", 0);
    pg_append_sync(w);

    if (!pg_flush_sync(w)) {
        res_error(res, 500, "database error");
        return;
    }

    bool found = false;
    char type;
    uint32_t len;
    const uint8_t *payload;

    while (1) {
        while (!pg_read_frame(w, &type, &len, &payload)) {
            ssize_t n = recv(w->fd, w->rx_buf + w->rx_len, sizeof(w->rx_buf) - w->rx_len, 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    struct pollfd pfd = { .fd = w->fd, .events = POLLIN };
                    poll(&pfd, 1, 1000);
                    continue;
                }
                res_error(res, 500, "database error");
                return;
            } else if (n == 0) {
                res_error(res, 500, "database error");
                return;
            }
            w->rx_len += (int)n;
        }

        if (type == 'D') {
            pg_row_t row;
            pg_parse_row(payload, len - 4, &row);
            res->status = 200;
            res->len = 0;
            RES_APPEND_LIT(res, "{\"article\":");
            format_article_row_wire(res, &row, true);
            RES_APPEND_LIT(res, "}");
            found = true;
        } else if (type == 'E') {
            char code[8];
            pg_extract_error_sqlstate(payload, len - 4, code);
            if (strcmp(code, "23505") == 0) {
                res_error(res, 422, "already taken");
            } else {
                res_error(res, 500, "database error");
            }
        } else if (type == 'Z') {
            pg_consume_frame(w, 1 + len);
            break;
        }

        pg_consume_frame(w, 1 + len);
    }

    if (!found && res->status == 200) {
        res_error(res, 404, "article not found");
    }
}

void db_list_comments(db_conn_t *db, int64_t viewer, const char *slug, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *sel_p[1] = { slug };
    const char *list_p[2] = { v_str, slug };

    pg_wire_conn_t *w = &db->wire;
    pg_append_bind(w, "", "sel_art_id", 1, sel_p, NULL);
    pg_append_exec(w, "", 0);
    pg_append_bind(w, "", "list_comm_slug", 2, list_p, NULL);
    pg_append_exec(w, "", 0);
    pg_append_sync(w);

    if (!pg_flush_sync(w)) {
        res_error(res, 500, "database error");
        return;
    }

    res->status = 200;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"comments\":[");

    int stmt_idx = 0;
    bool article_exists = false;
    int comment_count = 0;
    char type;
    uint32_t len;
    const uint8_t *payload;

    while (1) {
        while (!pg_read_frame(w, &type, &len, &payload)) {
            ssize_t n = recv(w->fd, w->rx_buf + w->rx_len, sizeof(w->rx_buf) - w->rx_len, 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    struct pollfd pfd = { .fd = w->fd, .events = POLLIN };
                    poll(&pfd, 1, 1000);
                    continue;
                }
                res_error(res, 500, "database error");
                return;
            } else if (n == 0) {
                res_error(res, 500, "database error");
                return;
            }
            w->rx_len += (int)n;
        }

        if (type == 'D') {
            if (stmt_idx == 0) {
                article_exists = true;
            } else if (stmt_idx == 1) {
                pg_row_t row;
                pg_parse_row(payload, len - 4, &row);
                if (comment_count > 0) RES_APPEND_LIT(res, ",");
                format_comment_row_wire(res, &row);
                comment_count++;
            }
        } else if (type == 'C') {
            stmt_idx++;
        } else if (type == 'E') {
            res_error(res, 500, "database error");
        } else if (type == 'Z') {
            pg_consume_frame(w, 1 + len);
            break;
        }

        pg_consume_frame(w, 1 + len);
    }

    if (!article_exists) {
        res_error(res, 404, "article not found");
        return;
    }

    RES_APPEND_LIT(res, "]}");
}

void db_create_comment(db_conn_t *db, int64_t viewer, const char *slug, const char *body, http_res_t *res) {
    char v_str[24];
    u64_to_str((uint64_t)viewer, v_str);
    const char *comm_p[3] = { slug, v_str, body };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "ins_comment_slug", 3, comm_p, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 404, "article not found");
        return;
    }
    res->status = 201;
    res->len = 0;
    RES_APPEND_LIT(res, "{\"comment\":");
    format_comment_row_wire(res, &rows[0]);
    RES_APPEND_LIT(res, "}");
}

void db_delete_comment(db_conn_t *db, int64_t viewer, const char *slug, int64_t comment_id, http_res_t *res) {
    char cid_str[24], v_str[24];
    u64_to_str((uint64_t)comment_id, cid_str);
    u64_to_str((uint64_t)viewer, v_str);
    const char *del_p[3] = { cid_str, slug, v_str };
    pg_row_t rows[1];
    int count = 0;
    if (!pg_wire_exec_query(&db->wire, "del_comment_cte", 3, del_p, rows, 1, &count, NULL) || count == 0) {
        res_error(res, 404, "comment not found");
        return;
    }
    int64_t author_id = strtoll(rows[0].col_vals[0], NULL, 10);
    if (author_id != viewer) {
        res_error(res, 403, "not the author");
        return;
    }
    res->status = 204;
    res->len = 0;
}


