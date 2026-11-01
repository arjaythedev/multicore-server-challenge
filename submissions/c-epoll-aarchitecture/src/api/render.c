#include "api/render.h"

#include <stdlib.h>
#include <string.h>

#include "core/json.h"

/* column layouts fixed by pg/statements.c.
 * user: 0 id, 1 username, 2 email, 3 bio, 4 image (login: 5 hash)
 * profile: 0 id, 1 username, 2 bio, 3 image, 4 following
 * article: id/slug/title/desc/created/updated/tags/count/favorited/
 *   author-username/bio/image/following; body at 4 when full
 * comment: following only in list shape */

static long long parse_id(const pg_result *res, int row, int col) {
    return strtoll(pg_result_value(res, row, col), NULL, 10);
}

static bool is_true(const pg_result *res, int row, int col) {
    return strcmp(pg_result_value(res, row, col), "t") == 0;
}

/* epoch micros -> RFC 3339 UTC with exactly 3 fractional digits (truncated);
 * civil date via Howard Hinnant's civil_from_days */
static void render_ts(buf *out, long long micros) {
    long long secs = micros / 1000000;
    long long ms = (micros / 1000) % 1000;
    long long sod = secs % 86400;
    long long hh = sod / 3600;
    long long mm = (sod / 60) % 60;
    long long ss = sod % 60;

    long long z = secs / 86400 + 719468;
    long long era = (z >= 0 ? z : z - 146096) / 146097;
    long long doe = z - era * 146097;
    long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long long y = yoe + era * 400;
    long long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long long mp = (5 * doy + 2) / 153;
    long long d = doy - (153 * mp + 2) / 5 + 1;
    long long m = mp + (mp < 10 ? 3 : -9);
    if (m <= 2) y++;

    char year[5] = {
        (char)('0' + y / 1000 % 10), (char)('0' + y / 100 % 10),
        (char)('0' + y / 10 % 10), (char)('0' + y % 10), 0,
    };
    buf_append(out, year, 4);
    buf_putc(out, '-');
    buf_putc(out, (char)('0' + m / 10));
    buf_putc(out, (char)('0' + m % 10));
    buf_putc(out, '-');
    buf_putc(out, (char)('0' + d / 10));
    buf_putc(out, (char)('0' + d % 10));
    BUF_LIT(out, "T");
    buf_putc(out, (char)('0' + hh / 10));
    buf_putc(out, (char)('0' + hh % 10));
    buf_putc(out, ':');
    buf_putc(out, (char)('0' + mm / 10));
    buf_putc(out, (char)('0' + mm % 10));
    buf_putc(out, ':');
    buf_putc(out, (char)('0' + ss / 10));
    buf_putc(out, (char)('0' + ss % 10));
    buf_putc(out, '.');
    buf_putc(out, (char)('0' + ms / 100));
    buf_putc(out, (char)('0' + ms / 10 % 10));
    buf_putc(out, (char)('0' + ms % 10));
    buf_putc(out, 'Z');
}

static const char *optional(const pg_result *res, int row, int col,
                            bool *is_null) {
    *is_null = pg_result_is_null(res, row, col);
    return *is_null ? NULL : pg_result_value(res, row, col);
}

void user_view_load(user_view *v, const pg_result *res, int row) {
    memset(v, 0, sizeof *v);
    v->username = pg_result_value(res, row, 1);
    v->email = pg_result_value(res, row, 2);
    v->bio = optional(res, row, 3, &v->bio_null);
    v->image = optional(res, row, 4, &v->image_null);
}

void profile_view_load(profile_view *v, const pg_result *res, int row) {
    memset(v, 0, sizeof *v);
    v->username = pg_result_value(res, row, 1);
    v->bio = optional(res, row, 2, &v->bio_null);
    v->image = optional(res, row, 3, &v->image_null);
    v->following = is_true(res, row, 4);
}

void article_view_load(article_view *v, const pg_result *res, int row,
                       bool full) {
    memset(v, 0, sizeof *v);
    int created_col = full ? 5 : 4;
    int tags_col = created_col + 2;
    int count_col = tags_col + 1;
    int favorited_col = count_col + 1;
    int author_col = favorited_col + 1;

    v->slug = pg_result_value(res, row, 1);
    v->title = pg_result_value(res, row, 2);
    v->description = pg_result_value(res, row, 3);
    if (full) {
        v->body = pg_result_value(res, row, 4);
        v->body_present = true;
    }
    v->created_at = parse_id(res, row, created_col);
    v->updated_at = parse_id(res, row, created_col + 1);
    v->tags = optional(res, row, tags_col, &v->tags_null);
    v->favorites_count = pg_result_value(res, row, count_col);
    v->favorited = is_true(res, row, favorited_col);
    v->author_username = pg_result_value(res, row, author_col);
    v->author_bio = optional(res, row, author_col + 1, &v->author_bio_null);
    v->author_image = optional(res, row, author_col + 2, &v->author_image_null);
    v->following = is_true(res, row, author_col + 3);
}

void comment_view_load(comment_view *v, const pg_result *res, int row,
                       bool with_following) {
    memset(v, 0, sizeof *v);
    v->id = parse_id(res, row, 0);
    v->body = pg_result_value(res, row, 1);
    v->created_at = parse_id(res, row, 2);
    v->updated_at = parse_id(res, row, 3);
    v->author_username = pg_result_value(res, row, 4);
    v->author_bio = optional(res, row, 5, &v->author_bio_null);
    v->author_image = optional(res, row, 6, &v->author_image_null);
    v->following = with_following && is_true(res, row, 7);
}

/* pg text[] literal: {a,b,"c d"}; quoted elems escape '"' and '\'. seed tags
 * have no commas, but parse quoting anyway */
void render_tag_array(buf *out, const char *literal) {
    if (!literal || literal[0] != '{') {
        BUF_LIT(out, "[]");
        return;
    }

    buf element;
    buf_init(&element);
    BUF_LIT(out, "[");
    const char *p = literal + 1;
    unsigned count = 0;

    if (*p == '}') {
        if (p[1] != '\0') goto malformed;
        BUF_LIT(out, "]");
        buf_free(&element);
        return;
    }

    for (;;) {
        buf_clear(&element);
        if (*p == '"') {
            p++;
            while (*p && *p != '"') {
                if (*p == '\\') {
                    if (!p[1]) goto malformed;
                    p++;
                }
                buf_putc(&element, *p++);
            }
            if (*p != '"') goto malformed;
            p++;
        } else {
            const char *start = p;
            while (*p && *p != ',' && *p != '}') p++;
            if (p == start) goto malformed;
            buf_append(&element, start, (size_t)(p - start));
        }

        if (count++) buf_putc(out, ',');
        json_quote_bytes(out, element.data, element.len);

        if (*p == ',') {
            p++;
            continue;
        }
        if (*p == '}' && p[1] == '\0') break;
        goto malformed;
    }

    BUF_LIT(out, "]");
    buf_free(&element);
    return;

    malformed:
    buf_free(&element);
    /* caller already wrote '['; must close it */
    BUF_LIT(out, "]");
}

static void render_nullable(buf *out, const char *value, bool is_null) {
    if (is_null) BUF_LIT(out, "null");
    else json_quote(out, value);
}

static void render_bool(buf *out, bool value) {
    if (value) BUF_LIT(out, "true");
    else BUF_LIT(out, "false");
}

void render_user(buf *out, const user_view *v, const char *token) {
    BUF_LIT(out, "{\"user\":{\"email\":");
    json_quote(out, v->email);
    BUF_LIT(out, ",\"token\":");
    if (token) json_quote(out, token);
    else BUF_LIT(out, "null");
    BUF_LIT(out, ",\"username\":");
    json_quote(out, v->username);
    BUF_LIT(out, ",\"bio\":");
    render_nullable(out, v->bio, v->bio_null);
    BUF_LIT(out, ",\"image\":");
    render_nullable(out, v->image, v->image_null);
    BUF_LIT(out, "}}");
}

void render_profile(buf *out, const profile_view *v) {
    BUF_LIT(out, "{\"profile\":{\"username\":");
    json_quote(out, v->username);
    BUF_LIT(out, ",\"bio\":");
    render_nullable(out, v->bio, v->bio_null);
    BUF_LIT(out, ",\"image\":");
    render_nullable(out, v->image, v->image_null);
    BUF_LIT(out, ",\"following\":");
    render_bool(out, v->following);
    BUF_LIT(out, "}}");
}

void render_article(buf *out, const article_view *v) {
    BUF_LIT(out, "{\"slug\":");
    json_quote(out, v->slug);
    BUF_LIT(out, ",\"title\":");
    json_quote(out, v->title);
    BUF_LIT(out, ",\"description\":");
    json_quote(out, v->description);
    if (v->body_present) {
        BUF_LIT(out, ",\"body\":");
        json_quote(out, v->body);
    }
    BUF_LIT(out, ",\"tagList\":");
    if (v->tags_null) BUF_LIT(out, "[]");
    else render_tag_array(out, v->tags);
    BUF_LIT(out, ",\"createdAt\":\"");
    render_ts(out, v->created_at);
    BUF_LIT(out, "\",\"updatedAt\":\"");
    render_ts(out, v->updated_at);
    BUF_LIT(out, "\",\"favorited\":");
    render_bool(out, v->favorited);
    BUF_LIT(out, ",\"favoritesCount\":");
    buf_append(out, v->favorites_count, strlen(v->favorites_count));
    BUF_LIT(out, ",\"author\":{\"username\":");
    json_quote(out, v->author_username);
    BUF_LIT(out, ",\"bio\":");
    render_nullable(out, v->author_bio, v->author_bio_null);
    BUF_LIT(out, ",\"image\":");
    render_nullable(out, v->author_image, v->author_image_null);
    BUF_LIT(out, ",\"following\":");
    render_bool(out, v->following);
    BUF_LIT(out, "}}");
}

void render_comment(buf *out, const comment_view *v) {
    buf_printf(out, "{\"id\":%lld,\"createdAt\":\"", v->id);
    render_ts(out, v->created_at);
    BUF_LIT(out, "\",\"updatedAt\":\"");
    render_ts(out, v->updated_at);
    BUF_LIT(out, "\",\"body\":");
    json_quote(out, v->body);
    BUF_LIT(out, ",\"author\":{\"username\":");
    json_quote(out, v->author_username);
    BUF_LIT(out, ",\"bio\":");
    render_nullable(out, v->author_bio, v->author_bio_null);
    BUF_LIT(out, ",\"image\":");
    render_nullable(out, v->author_image, v->author_image_null);
    BUF_LIT(out, ",\"following\":");
    render_bool(out, v->following);
    BUF_LIT(out, "}}");
}
