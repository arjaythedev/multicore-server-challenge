/* JSON response bodies rendered straight from Postgres binary-format rows (one NIF call per response), for the hot
 * reads. Each row is a DataRow's column data after its column count: per column an int32 length (-1 = NULL) and
 * that many bytes. Column layouts are those of the statements in Conduit.Sql (see Conduit.Render). The output is
 * byte-identical to the Erlang renderer it replaces (Conduit.Handler with RENDER_NIF=0): strings escaped as OTP's
 * :json.encode_binary does, timestamps as Conduit.Json.ts/1.
 *
 * Every read is bounds-checked and every row must consume exactly its columns; anything else raises badarg.
 * Responses are a few KB and render in microseconds, so these run on normal schedulers. */
#include <erl_nif.h>
#include <stdint.h>
#include <string.h>

/* ------------------------------------------------------------------ output buffer */

typedef struct {
    ErlNifBinary bin;
    size_t len;
    int ok;
    /* nmark >= 0: put_bool records where each boolean starts and ends (the *_parts NIFs) */
    int nmark;
    size_t mark[4];
} Out;

static int reserve(Out *o, size_t n) {
    if (!o->ok) return 0;
    if (o->len + n <= o->bin.size) return 1;
    size_t cap = o->bin.size * 2;
    while (cap < o->len + n) cap *= 2;
    if (!enif_realloc_binary(&o->bin, cap)) o->ok = 0;
    return o->ok;
}

static void put(Out *o, const void *p, size_t n) {
    if (!reserve(o, n)) return;
    memcpy(o->bin.data + o->len, p, n);
    o->len += n;
}

static void put_lit(Out *o, const char *s) { put(o, s, strlen(s)); }

static void put_char(Out *o, char c) { put(o, &c, 1); }

static const char hex[] = "0123456789ABCDEF";

/* As :json.encode_binary/1: named escapes for \b \t \n \f \r " \, \u00XX (uppercase) for other control
 * characters, every other byte (including 0x7F and UTF-8 sequences, valid as they come from Postgres) as is. */
static void put_str(Out *o, const uint8_t *s, size_t n) {
    if (!reserve(o, n * 6 + 2)) return;
    uint8_t *d = o->bin.data + o->len;
    *d++ = '"';
    for (size_t i = 0; i < n; i++) {
        uint8_t c = s[i];
        if (c >= 0x20 && c != '"' && c != '\\') {
            *d++ = c;
            continue;
        }
        *d++ = '\\';
        switch (c) {
        case '"': *d++ = '"'; break;
        case '\\': *d++ = '\\'; break;
        case '\b': *d++ = 'b'; break;
        case '\t': *d++ = 't'; break;
        case '\n': *d++ = 'n'; break;
        case '\f': *d++ = 'f'; break;
        case '\r': *d++ = 'r'; break;
        default:
            *d++ = 'u'; *d++ = '0'; *d++ = '0';
            *d++ = hex[c >> 4]; *d++ = hex[c & 15];
        }
    }
    *d++ = '"';
    o->len = (size_t)(d - o->bin.data);
}

static void put_int(Out *o, int64_t v) {
    char buf[24];
    int i = sizeof buf;
    uint64_t u = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    do {
        buf[--i] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    if (v < 0) buf[--i] = '-';
    put(o, buf + i, sizeof buf - (size_t)i);
}

static int64_t floor_div(int64_t a, int64_t b) {
    int64_t q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

static int64_t floor_mod(int64_t a, int64_t b) { return a - floor_div(a, b) * b; }

static void two(char *d, int64_t v) {
    d[0] = (char)('0' + v / 10);
    d[1] = (char)('0' + v % 10);
}

/* Postgres timestamptz (microseconds since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ", truncated to ms, as
 * Conduit.Json.ts/1 (Howard Hinnant's civil_from_days for the date). */
static void put_ts(Out *o, int64_t pg_micros) {
    int64_t unix_micros = pg_micros + INT64_C(946684800000000);
    int64_t secs = floor_div(unix_micros, 1000000);
    int64_t ms = floor_mod(unix_micros, 1000000) / 1000;
    int64_t z = floor_div(secs, 86400) + 719468;
    int64_t sod = floor_mod(secs, 86400);
    int64_t era = floor_div(z, 146097);
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    int64_t d = doy - (153 * mp + 2) / 5 + 1;
    int64_t m = mp < 10 ? mp + 3 : mp - 9;
    int64_t y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    char b[26];
    b[0] = '"';
    two(b + 1, y / 100); two(b + 3, y % 100); b[5] = '-';
    two(b + 6, m); b[8] = '-';
    two(b + 9, d); b[11] = 'T';
    two(b + 12, sod / 3600); b[14] = ':';
    two(b + 15, (sod / 60) % 60); b[17] = ':';
    two(b + 18, sod % 60); b[20] = '.';
    b[21] = (char)('0' + ms / 100); two(b + 22, ms % 100);
    b[24] = 'Z'; b[25] = '"';
    put(o, b, sizeof b);
}

/* ------------------------------------------------------------------ row parsing */

typedef struct {
    const uint8_t *p, *end;
    int bad;
} Row;

static uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static int64_t be64(const uint8_t *p) { return (int64_t)((uint64_t)be32(p) << 32 | be32(p + 4)); }

/* The next column: its bytes in *v (NULL for SQL NULL) and length in *n. */
static void col(Row *r, const uint8_t **v, size_t *n) {
    *v = NULL;
    *n = 0;
    if (r->bad || r->end - r->p < 4) { r->bad = 1; return; }
    int32_t len = (int32_t)be32(r->p);
    r->p += 4;
    if (len == -1) return;
    if (len < 0 || r->end - r->p < len) { r->bad = 1; return; }
    *v = r->p;
    *n = (size_t)len;
    r->p += len;
}

/* Column readers; a NULL where the statement can't produce one marks the row bad. */
static int64_t col_int8(Row *r) {
    const uint8_t *v; size_t n;
    col(r, &v, &n);
    if (!v || n != 8) { r->bad = 1; return 0; }
    return be64(v);
}

static int col_is_null(Row *r) {
    if (r->bad || r->end - r->p < 4) { r->bad = 1; return 0; }
    return (int32_t)be32(r->p) == -1;
}

static void skip(Row *r) {
    const uint8_t *v; size_t n;
    col(r, &v, &n);
}

static void put_text(Out *o, Row *r) {
    const uint8_t *v; size_t n;
    col(r, &v, &n);
    if (!v) { r->bad = 1; return; }
    put_str(o, v, n);
}

static void put_opt_text(Out *o, Row *r) {
    const uint8_t *v; size_t n;
    col(r, &v, &n);
    if (v) put_str(o, v, n); else put_lit(o, "null");
}

static void put_bool(Out *o, Row *r) {
    const uint8_t *v; size_t n;
    col(r, &v, &n);
    if (!v || n != 1) { r->bad = 1; return; }
    if (o->nmark >= 0 && o->nmark < 4) o->mark[o->nmark++] = o->len;
    put_lit(o, v[0] ? "true" : "false");
    if (o->nmark >= 0 && o->nmark < 4) o->mark[o->nmark++] = o->len;
}

static void put_ts_col(Out *o, Row *r) { put_ts(o, col_int8(r)); }

static void put_int_col(Out *o, Row *r) { put_int(o, col_int8(r)); }

/* text[] in binary array format: ndim, has-null flag, element oid, then for ndim 1 the length and lower bound, then
 * each element as length + bytes. Written as a JSON array of strings. */
static void put_text_array(Out *o, Row *r) {
    const uint8_t *v; size_t n;
    col(r, &v, &n);
    if (!v || n < 12) { r->bad = 1; return; }
    uint32_t ndim = be32(v);
    put_char(o, '[');
    if (ndim == 1) {
        if (n < 20) { r->bad = 1; return; }
        uint32_t count = be32(v + 12);
        Row a = {v + 20, v + n, 0};
        for (uint32_t i = 0; i < count && !a.bad; i++) {
            if (i) put_char(o, ',');
            put_text(o, &a);
        }
        if (a.bad || a.p != a.end) r->bad = 1;
    } else if (ndim != 0 || n != 12) {
        r->bad = 1;
    }
    put_char(o, ']');
}

/* ------------------------------------------------------------------ objects */

/* username, bio, image, following -> Profile */
static void put_profile(Out *o, Row *r) {
    put_lit(o, "{\"username\":");
    put_text(o, r);
    put_lit(o, ",\"bio\":");
    put_opt_text(o, r);
    put_lit(o, ",\"image\":");
    put_opt_text(o, r);
    put_lit(o, ",\"following\":");
    put_bool(o, r);
    put_char(o, '}');
}

/* id, slug, title, description, [body,] created_at, updated_at, tag_list, favorites_count, favorited, username, bio,
 * image, following -> Article */
static void put_article(Out *o, Row *r, int with_body) {
    skip(r); /* id */
    put_lit(o, "{\"slug\":");
    put_text(o, r);
    put_lit(o, ",\"title\":");
    put_text(o, r);
    put_lit(o, ",\"description\":");
    put_text(o, r);
    if (with_body) {
        put_lit(o, ",\"body\":");
        put_text(o, r);
    }
    /* created and updated come before tagList in the row but after it in the object */
    const uint8_t *created_v, *updated_v;
    size_t created_n, updated_n;
    col(r, &created_v, &created_n);
    col(r, &updated_v, &updated_n);
    if (!created_v || created_n != 8 || !updated_v || updated_n != 8) { r->bad = 1; return; }
    put_lit(o, ",\"tagList\":");
    put_text_array(o, r);
    put_lit(o, ",\"createdAt\":");
    put_ts(o, be64(created_v));
    put_lit(o, ",\"updatedAt\":");
    put_ts(o, be64(updated_v));
    /* favorites_count comes before favorited in the row, after it in the object */
    int64_t count = col_int8(r);
    put_lit(o, ",\"favorited\":");
    put_bool(o, r);
    put_lit(o, ",\"favoritesCount\":");
    put_int(o, count);
    put_lit(o, ",\"author\":");
    put_profile(o, r);
    put_char(o, '}');
}

/* ------------------------------------------------------------------ NIFs */

static int start(ErlNifEnv *env, Out *o, size_t cap) {
    o->len = 0;
    o->nmark = -1;
    o->ok = enif_alloc_binary(cap, &o->bin);
    return o->ok;
}

static ERL_NIF_TERM finish(ErlNifEnv *env, Out *o, int bad) {
    if (bad || !o->ok) {
        if (o->ok) enif_release_binary(&o->bin);
        return enif_make_badarg(env);
    }
    if (o->len != o->bin.size && !enif_realloc_binary(&o->bin, o->len)) {
        enif_release_binary(&o->bin);
        return enif_make_badarg(env);
    }
    return enif_make_binary(env, &o->bin);
}

static int row_of(ErlNifEnv *env, ERL_NIF_TERM term, Row *r) {
    ErlNifBinary b;
    if (!enif_inspect_binary(env, term, &b)) return 0;
    r->p = b.data;
    r->end = b.data + b.size;
    r->bad = 0;
    return 1;
}

/* list(Rows): n, then an Article without body (all NULL on an empty page) -> {"articles":[...],"articlesCount":n} */
static ERL_NIF_TERM render_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Out o;
    if (!start(env, &o, 8192)) return enif_make_badarg(env);
    put_lit(&o, "{\"articles\":[");
    ERL_NIF_TERM head, list = argv[0];
    int64_t count = 0;
    int first = 1, items = 0, bad = 0;
    while (!bad && enif_get_list_cell(env, list, &head, &list)) {
        Row r;
        if (!row_of(env, head, &r)) { bad = 1; break; }
        int64_t n = col_int8(&r);
        if (first) count = n;
        first = 0;
        if (col_is_null(&r)) {
            for (int i = 0; i < 13; i++) skip(&r);
        } else {
            if (items++) put_char(&o, ',');
            put_article(&o, &r, 0);
        }
        bad = r.bad || r.p != r.end;
    }
    put_lit(&o, "],\"articlesCount\":");
    put_int(&o, count);
    put_char(&o, '}');
    return finish(env, &o, bad || !enif_is_empty_list(env, list));
}

/* article(Row): an Article with body -> {"article":{...}} */
static ERL_NIF_TERM render_article(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Out o;
    Row r;
    if (!row_of(env, argv[0], &r) || !start(env, &o, 4096)) return enif_make_badarg(env);
    put_lit(&o, "{\"article\":");
    put_article(&o, &r, 1);
    put_char(&o, '}');
    return finish(env, &o, r.bad || r.p != r.end);
}

/* comment id, body, created_at, updated_at, username, bio, image, following -> Comment */
static void put_comment(Out *o, Row *r) {
    put_lit(o, "{\"id\":");
    put_int_col(o, r);
    const uint8_t *body; size_t body_n;
    col(r, &body, &body_n);
    if (!body) r->bad = 1;
    put_lit(o, ",\"createdAt\":");
    put_ts_col(o, r);
    put_lit(o, ",\"updatedAt\":");
    put_ts_col(o, r);
    put_lit(o, ",\"body\":");
    if (body) put_str(o, body, body_n);
    put_lit(o, ",\"author\":");
    put_profile(o, r);
    put_char(o, '}');
}

/* comments(Rows): article_id, comment id, body, created_at, updated_at, username, bio, image, following (comment
 * columns all NULL when there are none) -> {"comments":[...]} */
static ERL_NIF_TERM render_comments(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Out o;
    if (!start(env, &o, 4096)) return enif_make_badarg(env);
    put_lit(&o, "{\"comments\":[");
    ERL_NIF_TERM head, list = argv[0];
    int items = 0, bad = 0;
    while (!bad && enif_get_list_cell(env, list, &head, &list)) {
        Row r;
        if (!row_of(env, head, &r)) { bad = 1; break; }
        skip(&r); /* article id */
        if (col_is_null(&r)) {
            for (int i = 0; i < 8; i++) skip(&r);
        } else {
            if (items++) put_char(&o, ',');
            put_comment(&o, &r);
        }
        bad = r.bad || r.p != r.end;
    }
    put_lit(&o, "]}");
    return finish(env, &o, bad || !enif_is_empty_list(env, list));
}

/* profile(Row): id, username, bio, image, following -> {"profile":{...}} */
static ERL_NIF_TERM render_profile(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Out o;
    Row r;
    if (!row_of(env, argv[0], &r) || !start(env, &o, 512)) return enif_make_badarg(env);
    skip(&r); /* id */
    put_lit(&o, "{\"profile\":");
    put_profile(&o, &r);
    put_char(&o, '}');
    return finish(env, &o, r.bad || r.p != r.end);
}

/* tags(Row): text[] -> {"tags":[...]} */
static ERL_NIF_TERM render_tags(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Out o;
    Row r;
    if (!row_of(env, argv[0], &r) || !start(env, &o, 4096)) return enif_make_badarg(env);
    put_lit(&o, "{\"tags\":");
    put_text_array(&o, &r);
    put_char(&o, '}');
    return finish(env, &o, r.bad || r.p != r.end);
}

/* The pieces of a response around its viewer's booleans, for read plans (Conduit.Plan), which render each article or
 * comment once and splice the booleans per response. The row is the one render_list/render_article/render_comments
 * take (its booleans are placeholders); the pieces are sub-binaries of one rendering. */
static ERL_NIF_TERM parts(ErlNifEnv *env, Out *o, int bad, int marks) {
    if (bad || !o->ok || o->nmark != marks) return finish(env, o, 1);
    size_t len = o->len;
    ERL_NIF_TERM bin = finish(env, o, 0);
    if (!enif_is_binary(env, bin)) return bin;
    if (marks == 4)
        return enif_make_tuple3(env, enif_make_sub_binary(env, bin, 0, o->mark[0]),
                                enif_make_sub_binary(env, bin, o->mark[1], o->mark[2] - o->mark[1]),
                                enif_make_sub_binary(env, bin, o->mark[3], len - o->mark[3]));
    return enif_make_tuple2(env, enif_make_sub_binary(env, bin, 0, o->mark[0]),
                            enif_make_sub_binary(env, bin, o->mark[1], len - o->mark[1]));
}

/* article_parts(Row, WithBody) -> {before favorited, between favorited and following, after following} */
static ERL_NIF_TERM render_article_parts(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Out o;
    Row r;
    int with_body;
    if (!enif_get_int(env, argv[1], &with_body) || !row_of(env, argv[0], &r) || !start(env, &o, 1024))
        return enif_make_badarg(env);
    o.nmark = 0;
    put_article(&o, &r, with_body);
    return parts(env, &o, r.bad || r.p != r.end, 4);
}

/* comment_parts(Row): a comments row without its article id -> {before following, after following} */
static ERL_NIF_TERM render_comment_parts(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Out o;
    Row r;
    if (!row_of(env, argv[0], &r) || !start(env, &o, 512)) return enif_make_badarg(env);
    o.nmark = 0;
    put_comment(&o, &r);
    return parts(env, &o, r.bad || r.p != r.end, 2);
}

/* Read plans' own rows (Conduit.Sql plan_articles / plan_comments), rendered straight to pieces: their column spans
 * (header included) are copied into the layout article_parts / comment_parts take, with `false` placeholders for
 * the booleans, and rendered by the same writers. */
typedef struct {
    const uint8_t *p;
    size_t n;
} Span;

static const uint8_t BOOL_FALSE[5] = {0, 0, 0, 1, 0};

/* the next k columns' spans; 0 if the row is shorter */
static int spans(Row *r, Span *s, int k) {
    for (int i = 0; i < k; i++) {
        const uint8_t *start = r->p, *v;
        size_t n;
        col(r, &v, &n);
        if (r->bad) return 0;
        s[i].p = start;
        s[i].n = (size_t)(r->p - start);
    }
    return 1;
}

static int span_int8(Span s, int64_t *out) {
    if (s.n != 12 || be32(s.p) != 8) return 0;
    *out = be64(s.p + 4);
    return 1;
}

/* Renders `segs` (spans and placeholders, in order) laid out as one row (in *scratch, grown as needed) and appended
 * to `o`, its booleans' marks recorded from o->mark[0]: 1 if it rendered. */
static int render_segs(Out *o, uint8_t **scratch, size_t *cap, Span *segs, int k, int is_article, int with_body) {
    size_t total = 0;
    for (int i = 0; i < k; i++) total += segs[i].n;
    if (total > *cap) {
        uint8_t *buf = enif_alloc(total);
        if (!buf) return 0;
        if (*scratch) enif_free(*scratch);
        *scratch = buf;
        *cap = total;
    }
    size_t at = 0;
    for (int i = 0; i < k; i++) {
        memcpy(*scratch + at, segs[i].p, segs[i].n);
        at += segs[i].n;
    }
    Row t = {*scratch, *scratch + total, 0};
    o->nmark = 0;
    if (is_article) put_article(o, &t, with_body); else put_comment(o, &t);
    int ok = !t.bad && t.p == t.end && o->ok && o->nmark == (is_article ? 4 : 2);
    o->nmark = -1;
    return ok;
}

/* the pieces of a rendering of `segs` laid out as one row */
static ERL_NIF_TERM render_spans(ErlNifEnv *env, Span *segs, int k, int is_article, int with_body) {
    uint8_t *scratch = NULL;
    size_t cap = 0;
    Out o;
    ERL_NIF_TERM res;
    if (!start(env, &o, is_article ? 1024 : 512)) {
        res = enif_make_badarg(env);
    } else {
        int ok = render_segs(&o, &scratch, &cap, segs, k, is_article, with_body);
        o.nmark = is_article ? 4 : 2;
        res = parts(env, &o, !ok, is_article ? 4 : 2);
    }
    if (scratch) enif_free(scratch);
    return res;
}

/* A plan_articles row (id, slug, title, description, created_at, updated_at, tag_list, favorites_count, author_id,
 * username, bio, image): its 12 column spans, id and author id; 0 if malformed. */
static int article_spans(Row *r, Span *s, int64_t *id, int64_t *author) {
    return spans(r, s, 12) && r->p == r->end && span_int8(s[0], id) && span_int8(s[8], author);
}

/* those spans (and the body column's span from plan_slug, or NULL) laid out as article_parts' row: k segments */
static int article_layout(const Span *s, const Span *body, Span *segs) {
    Span f = {BOOL_FALSE, 5};
    int k = 0;
    for (int i = 0; i < 4; i++) segs[k++] = s[i];
    if (body) segs[k++] = *body;
    for (int i = 4; i < 8; i++) segs[k++] = s[i];
    segs[k++] = f;
    for (int i = 9; i < 12; i++) segs[k++] = s[i];
    segs[k++] = f;
    return k;
}

/* plan_article(Row, Body): a plan_articles row and nil, or the body column's span (from plan_slug) ->
 * {id, author id, {a, b, c}} as article_parts gives for that article (without or with its body) */
static ERL_NIF_TERM render_plan_article(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Row r;
    Span s[12], segs[14];
    int64_t id, author;
    if (!row_of(env, argv[0], &r) || !article_spans(&r, s, &id, &author)) return enif_make_badarg(env);
    ErlNifBinary body;
    int with_body = enif_inspect_binary(env, argv[1], &body);
    Span b = {body.data, with_body ? body.size : 0};
    int k = article_layout(s, with_body ? &b : NULL, segs);
    ERL_NIF_TERM pieces = render_spans(env, segs, k, 1, with_body);
    if (!enif_is_tuple(env, pieces)) return pieces;
    return enif_make_tuple3(env, enif_make_int64(env, id), enif_make_int64(env, author), pieces);
}

/* A plan_comments row (ordinal, article id, comment id, body, created_at, updated_at, author_id, username, bio,
 * image; the comment's columns NULL for none): its ordinal, and unless it is none (*none = 1) its author and
 * comment_parts' row layout in segs[8]; 0 if malformed. */
static int comment_row(Row *r, int64_t *ord, int *none, int64_t *author, Span *segs) {
    Span s[10];
    if (!spans(r, s, 10) || r->p != r->end || !span_int8(s[0], ord)) return 0;
    *none = s[2].n == 4;
    if (*none) return 1;
    if (!span_int8(s[6], author)) return 0;
    Span l[8] = {s[2], s[3], s[4], s[5], s[7], s[8], s[9], {BOOL_FALSE, 5}};
    memcpy(segs, l, sizeof l);
    return 1;
}

/* plan_comment(Row): a plan_comments row -> {ordinal, author id, {a, c}} as comment_parts gives, or {ordinal, none} */
static ERL_NIF_TERM render_plan_comment(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Row r;
    Span segs[8];
    int64_t ord, author;
    int none;
    if (!row_of(env, argv[0], &r) || !comment_row(&r, &ord, &none, &author, segs)) return enif_make_badarg(env);
    if (none) return enif_make_tuple2(env, enif_make_int64(env, ord), enif_make_atom(env, "none"));
    ERL_NIF_TERM pieces = render_spans(env, segs, 8, 0, 0);
    if (!enif_is_tuple(env, pieces)) return pieces;
    return enif_make_tuple3(env, enif_make_int64(env, ord), enif_make_int64(env, author), pieces);
}

/* ------------------------------------------------------------------ whole plans (Conduit.Plan, PLAN_NIF=1) */

/* A plan's context (a resource, used only by the process that made it): the raw rows of its statements go in chunk
 * by chunk as they arrive (plan_add), rendered to pieces once (each distinct article, its full version for a slug,
 * each comment) into one buffer, with the page ids, the favorites and follows sets; plan_bodies then assembles each
 * request's finished body from the pieces and its viewer's booleans, byte for byte Conduit.Plan's Erlang path. */

enum { KINDS = 7, K_FEED = 4, K_SLUG = 5, K_COMMENTS = 6, T_ARTICLES = 7, T_FAVS = 8, T_FOLLOWS = 9, T_COUNTS = 10 };
enum { MAX_SLOT = 1 << 20 };

static ErlNifResourceType *plan_type;
static ERL_NIF_TERM atom_ok, atom_nil, atom_fallback, atom_encoded;

/* a byte range of the plan's text buffer */
typedef struct {
    size_t off, len;
} Piece;

/* open addressing over (a, b) keys; values >= 0 */
typedef struct {
    uint64_t *ka, *kb;
    int32_t *v; /* value + 1, 0 = empty */
    size_t cap, n;
} Map;

static uint64_t mix(uint64_t a, uint64_t b) {
    uint64_t h = a * UINT64_C(0x9E3779B97F4A7C15) ^ (b + UINT64_C(0x632BE59BD9B4E019)) * UINT64_C(0xC2B2AE3D27D4EB4F);
    h ^= h >> 29;
    h *= UINT64_C(0xBF58476D1CE4E5B9);
    return h ^ (h >> 32);
}

static void map_free(Map *m) {
    if (m->ka) enif_free(m->ka);
    if (m->kb) enif_free(m->kb);
    if (m->v) enif_free(m->v);
}

static int32_t map_get(const Map *m, uint64_t a, uint64_t b) {
    if (!m->cap) return -1;
    size_t mask = m->cap - 1, i = (size_t)mix(a, b) & mask;
    while (m->v[i]) {
        if (m->ka[i] == a && m->kb[i] == b) return m->v[i] - 1;
        i = (i + 1) & mask;
    }
    return -1;
}

static void map_insert(Map *m, uint64_t a, uint64_t b, int32_t v) {
    size_t mask = m->cap - 1, i = (size_t)mix(a, b) & mask;
    while (m->v[i]) i = (i + 1) & mask;
    m->ka[i] = a;
    m->kb[i] = b;
    m->v[i] = v + 1;
    m->n++;
}

/* 1 if (a, b) was new (now mapped to v), 0 if it was there already (unchanged), -1 out of memory */
static int map_put(Map *m, uint64_t a, uint64_t b, int32_t v) {
    if (map_get(m, a, b) >= 0) return 0;
    if ((m->n + 1) * 2 > m->cap) {
        Map g = {0};
        g.cap = m->cap ? m->cap * 2 : 64;
        g.ka = enif_alloc(g.cap * sizeof *g.ka);
        g.kb = enif_alloc(g.cap * sizeof *g.kb);
        g.v = enif_alloc(g.cap * sizeof *g.v);
        if (!g.ka || !g.kb || !g.v) { map_free(&g); return -1; }
        memset(g.v, 0, g.cap * sizeof *g.v);
        for (size_t i = 0; i < m->cap; i++)
            if (m->v[i]) map_insert(&g, m->ka[i], m->kb[i], m->v[i] - 1);
        map_free(m);
        *m = g;
    }
    map_insert(m, a, b, v);
    return 1;
}

/* *p (an array of *cap elements of `size` bytes) grown to hold `need`; 0 out of memory */
static int grow(void **p, size_t *cap, size_t need, size_t size) {
    if (need <= *cap) return 1;
    size_t c = *cap ? *cap : 16;
    while (c < need) c *= 2;
    void *q = *p ? enif_realloc(*p, c * size) : enif_alloc(c * size);
    if (!q) return 0;
    *p = q;
    *cap = c;
    return 1;
}

typedef struct {
    int64_t id, author;
    Piece a, b, c; /* the article without body: a <> favorited <> b <> following <> c */
} Art;

typedef struct {
    int64_t author;
    Piece a, c; /* a <> following <> c */
} Com;

/* a phase A key's row */
typedef struct {
    int present, full;
    int64_t n;           /* lists: capped count; slug: article id */
    size_t first, count; /* lists: page ids (in pages); comments: comments (in coms); slug: body column (in raw) */
    int64_t author;      /* slug, once full: the article with its body */
    Piece a, b, c;
} Slot;

typedef struct {
    ErlNifPid owner;
    Out text; /* every piece */
    int text_alloc;
    uint8_t *scratch, *raw;
    size_t cscratch, nraw, craw;
    Slot *slots[KINDS];
    size_t nslots[KINDS], cslots[KINDS];
    int64_t *pages, *ids, *authors; /* page ids; distinct article ids of phase A; distinct authors */
    size_t npages, cpages, nids, cids, nauthors, cauthors;
    Art *arts;
    size_t narts, carts;
    Com *coms;
    size_t ncoms, ccoms;
    Map id_seen, art_of, slug_of, author_seen, favs, follows;
    /* counted: the favorite counts came from Conduit.PlanCounts (T_COUNTS rows, id -> count), and every article's
     * count column is a placeholder they replace */
    Map counts;
    int counted;
} Plan;

static void plan_dtor(ErlNifEnv *env, void *obj) {
    Plan *p = obj;
    if (p->text_alloc) enif_release_binary(&p->text.bin);
    void *arrays[] = {p->scratch, p->raw, p->pages, p->ids, p->authors, p->arts, p->coms};
    for (size_t i = 0; i < sizeof arrays / sizeof *arrays; i++)
        if (arrays[i]) enif_free(arrays[i]);
    for (int k = 0; k < KINDS; k++)
        if (p->slots[k]) enif_free(p->slots[k]);
    Map *maps[] = {&p->id_seen, &p->art_of, &p->slug_of, &p->author_seen, &p->favs, &p->follows, &p->counts};
    for (size_t i = 0; i < sizeof maps / sizeof *maps; i++) map_free(maps[i]);
}

static Plan *plan_of(ErlNifEnv *env, ERL_NIF_TERM term) {
    Plan *p;
    ErlNifPid self;
    if (!enif_get_resource(env, term, plan_type, (void **)&p) || !enif_self(env, &self) ||
        enif_compare_pids(&self, &p->owner) != 0 || !p->text.ok)
        return NULL;
    return p;
}

/* plan_new() -> a context for one plan */
static ERL_NIF_TERM plan_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Plan *p = enif_alloc_resource(plan_type, sizeof(Plan));
    if (!p) return enif_make_badarg(env);
    memset(p, 0, sizeof *p);
    enif_self(env, &p->owner);
    p->text_alloc = start(env, &p->text, 65536);
    ERL_NIF_TERM t = enif_make_resource(env, p);
    enif_release_resource(p);
    return p->text_alloc ? t : enif_make_badarg(env);
}

static int add_id(Map *seen, int64_t **v, size_t *n, size_t *cap, int64_t id) {
    int r = map_put(seen, (uint64_t)id, 0, 0);
    if (r <= 0) return r == 0;
    if (!grow((void **)v, cap, *n + 1, sizeof **v)) return 0;
    (*v)[(*n)++] = id;
    return 1;
}

/* the slot for ordinal `ord` of a chunk starting at `base`, NULL if out of range */
static Slot *slot_at(Plan *p, int k, int64_t base, int64_t ord) {
    if (base < 0 || ord < 1 || base > MAX_SLOT || ord > MAX_SLOT) return NULL;
    size_t i = (size_t)(base + ord - 1);
    if (i >= p->nslots[k]) {
        if (!grow((void **)&p->slots[k], &p->cslots[k], i + 1, sizeof(Slot))) return NULL;
        memset(p->slots[k] + p->nslots[k], 0, (i + 1 - p->nslots[k]) * sizeof(Slot));
        p->nslots[k] = i + 1;
    }
    return p->slots[k] + i;
}

/* renders segs to pieces appended to the text buffer: 1 if it rendered */
static int render_pieces(Plan *p, Span *segs, int k, int is_article, int with_body, Piece *a, Piece *b, Piece *c) {
    size_t from = p->text.len;
    if (!render_segs(&p->text, &p->scratch, &p->cscratch, segs, k, is_article, with_body)) return 0;
    size_t *m = p->text.mark;
    *a = (Piece){from, m[0] - from};
    if (is_article) {
        *b = (Piece){m[1], m[2] - m[1]};
        *c = (Piece){m[3], p->text.len - m[3]};
    } else {
        *c = (Piece){m[1], p->text.len - m[1]};
    }
    return 1;
}

/* a list / feed row of phase A: ordinal, capped count, page ids (int8[]) */
static int add_page(Plan *p, int k, int64_t base, Row *r) {
    int64_t ord = col_int8(r), n = col_int8(r);
    const uint8_t *v;
    size_t len;
    col(r, &v, &len);
    if (r->bad || !v || r->p != r->end || len < 12) return 0;
    size_t count = 0;
    const uint8_t *e = v + 20;
    if (be32(v) == 0) {
        if (len != 12) return 0;
    } else {
        if (be32(v) != 1 || len < 20 || be32(v + 8) != 20) return 0;
        count = be32(v + 12);
        if (count > (len - 20) / 12 || len != 20 + 12 * count) return 0;
    }
    Slot *s = slot_at(p, k, base, ord);
    if (!s || s->present || !grow((void **)&p->pages, &p->cpages, p->npages + count, sizeof(int64_t))) return 0;
    s->present = 1;
    s->n = n;
    s->first = p->npages;
    s->count = count;
    for (size_t i = 0; i < count; i++, e += 12) {
        if (be32(e) != 8) return 0;
        int64_t id = be64(e + 4);
        p->pages[p->npages++] = id;
        if (!add_id(&p->id_seen, &p->ids, &p->nids, &p->cids, id)) return 0;
    }
    return 1;
}

/* a plan_slug row: ordinal, article id, body column (kept for the article's full rendering) */
static int add_slug(Plan *p, int64_t base, Row *r) {
    Span s[3];
    int64_t ord, id;
    if (!spans(r, s, 3) || r->p != r->end || !span_int8(s[0], &ord) || !span_int8(s[1], &id) || s[2].n < 4 ||
        (int32_t)be32(s[2].p) < 0)
        return 0;
    Slot *slot = slot_at(p, K_SLUG, base, ord);
    if (!slot || slot->present || !grow((void **)&p->raw, &p->craw, p->nraw + s[2].n, 1)) return 0;
    memcpy(p->raw + p->nraw, s[2].p, s[2].n);
    slot->present = 1;
    slot->n = id;
    slot->first = p->nraw;
    slot->count = s[2].n;
    p->nraw += s[2].n;
    if (map_put(&p->slug_of, (uint64_t)id, 0, (int32_t)(slot - p->slots[K_SLUG])) < 0) return 0;
    return add_id(&p->id_seen, &p->ids, &p->nids, &p->cids, id);
}

/* a plan_comments row: a thread's rows are consecutive (ORDER BY ordinal) */
static int add_comment(Plan *p, int64_t base, Row *r) {
    Span segs[8];
    int64_t ord, author = 0;
    int none;
    if (!comment_row(r, &ord, &none, &author, segs)) return 0;
    Slot *s = slot_at(p, K_COMMENTS, base, ord);
    if (!s) return 0;
    if (!s->present) {
        s->present = 1;
        s->first = p->ncoms;
        s->count = 0;
        if (none) return 1;
    } else if (none || s->first + s->count != p->ncoms) {
        return 0;
    }
    if (!grow((void **)&p->coms, &p->ccoms, p->ncoms + 1, sizeof(Com))) return 0;
    Com *c = p->coms + p->ncoms;
    c->author = author;
    if (!render_pieces(p, segs, 8, 0, 0, &c->a, NULL, &c->c)) return 0;
    p->ncoms++;
    s->count++;
    return add_id(&p->author_seen, &p->authors, &p->nauthors, &p->cauthors, author);
}

/* a plan_articles row: rendered without body, and with it if a slug of the plan is this article */
static int add_article(Plan *p, Row *r) {
    Span s[12], segs[14];
    int64_t id, author;
    if (!article_spans(r, s, &id, &author)) return 0;
    if (map_get(&p->art_of, (uint64_t)id, 0) >= 0) return 1;
    uint8_t count[12] = {0, 0, 0, 8};
    if (p->counted) {
        int32_t n = map_get(&p->counts, (uint64_t)id, 0);
        if (n < 0) return 0;
        for (int j = 0; j < 8; j++) count[4 + j] = (uint8_t)((uint64_t)n >> (56 - 8 * j));
        s[7] = (Span){count, sizeof count};
    }
    if (!grow((void **)&p->arts, &p->carts, p->narts + 1, sizeof(Art))) return 0;
    Art *a = p->arts + p->narts;
    a->id = id;
    a->author = author;
    if (!render_pieces(p, segs, article_layout(s, NULL, segs), 1, 0, &a->a, &a->b, &a->c)) return 0;
    if (map_put(&p->art_of, (uint64_t)id, 0, (int32_t)p->narts) < 0) return 0;
    p->narts++;
    int32_t sl = map_get(&p->slug_of, (uint64_t)id, 0);
    if (sl >= 0) {
        Slot *slot = p->slots[K_SLUG] + sl;
        Span body = {p->raw + slot->first, slot->count};
        if (!render_pieces(p, segs, article_layout(s, &body, segs), 1, 1, &slot->a, &slot->b, &slot->c)) return 0;
        slot->author = author;
        slot->full = 1;
    }
    return add_id(&p->author_seen, &p->authors, &p->nauthors, &p->cauthors, author);
}

/* a plan_favs / plan_follows row: two int8 */
static int add_pair(Map *m, Row *r) {
    int64_t a = col_int8(r), b = col_int8(r);
    return !r->bad && r->p == r->end && map_put(m, (uint64_t)a, (uint64_t)b, 0) >= 0;
}

/* a plan_counts row: article id, favorite count */
static int add_count(Map *m, Row *r) {
    int64_t id = col_int8(r), n = col_int8(r);
    return !r->bad && r->p == r->end && n >= 0 && n < INT32_MAX && map_put(m, (uint64_t)id, 0, (int32_t)n) >= 0;
}

/* plan_add(Plan, Table, Base, Rows) -> ok. Table: 0-6 a phase A statement's rows (Conduit.Plan's kinds in order,
 * ordinal i being slot Base + i - 1 of that kind), 7 plan_articles, 8 plan_favs, 9 plan_follows, 10 plan_counts
 * (before any article: from then on every article's count is its row's). */
static ERL_NIF_TERM plan_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Plan *p = plan_of(env, argv[0]);
    int t;
    ErlNifSInt64 base;
    if (!p || !enif_get_int(env, argv[1], &t) || t < 0 || t > T_COUNTS || !enif_get_int64(env, argv[2], &base))
        return enif_make_badarg(env);
    if (t == T_COUNTS) {
        if (p->narts) return enif_make_badarg(env);
        p->counted = 1;
    }
    ERL_NIF_TERM head, list = argv[3];
    while (enif_get_list_cell(env, list, &head, &list)) {
        Row r;
        if (!row_of(env, head, &r)) return enif_make_badarg(env);
        int ok;
        switch (t) {
        case K_SLUG: ok = add_slug(p, base, &r); break;
        case K_COMMENTS: ok = add_comment(p, base, &r); break;
        case T_ARTICLES: ok = add_article(p, &r); break;
        case T_FAVS: ok = add_pair(&p->favs, &r); break;
        case T_FOLLOWS: ok = add_pair(&p->follows, &r); break;
        case T_COUNTS: ok = add_count(&p->counts, &r); break;
        default: ok = add_page(p, t, base, &r);
        }
        if (!ok || !p->text.ok) return enif_make_badarg(env);
    }
    return enif_is_empty_list(env, list) ? atom_ok : enif_make_badarg(env);
}

/* {encoded, int8[] parameter} as Conduit.Pg.Proto.encode_param/2 gives */
static ERL_NIF_TERM int8_param(ErlNifEnv *env, const int64_t *v, size_t n) {
    ERL_NIF_TERM bin;
    size_t size = n ? 24 + 12 * n : 16;
    uint8_t *d = enif_make_new_binary(env, size, &bin);
    uint32_t head[6] = {(uint32_t)(size - 4), n ? 1 : 0, 0, 20, (uint32_t)n, 1};
    for (int i = 0; i < (n ? 6 : 4); i++, d += 4)
        for (int j = 0; j < 4; j++) d[j] = (uint8_t)(head[i] >> (24 - 8 * j));
    for (size_t i = 0; i < n; i++, d += 12) {
        uint64_t u = (uint64_t)v[i];
        d[0] = d[1] = d[2] = 0;
        d[3] = 8;
        for (int j = 0; j < 8; j++) d[4 + j] = (uint8_t)(u >> (56 - 8 * j));
    }
    return enif_make_tuple2(env, atom_encoded, bin);
}

/* plan_ids(Plan, Chunk) -> {all, [chunk]}: phase A's distinct article ids as int8[] parameters, all of them and in
 * chunks of at most Chunk ([] when there are none) */
static ERL_NIF_TERM plan_ids(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Plan *p = plan_of(env, argv[0]);
    int chunk;
    if (!p || !enif_get_int(env, argv[1], &chunk) || chunk < 1) return enif_make_badarg(env);
    ERL_NIF_TERM parts = enif_make_list(env, 0);
    for (size_t end = p->nids; end > 0;) {
        size_t from = (end - 1) / (size_t)chunk * (size_t)chunk;
        parts = enif_make_list_cell(env, int8_param(env, p->ids + from, end - from), parts);
        end = from;
    }
    return enif_make_tuple2(env, int8_param(env, p->ids, p->nids), parts);
}

/* plan_authors(Plan) -> {n, int8[] parameter}: the distinct authors of the articles and comments added so far */
static ERL_NIF_TERM plan_authors(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Plan *p = plan_of(env, argv[0]);
    if (!p) return enif_make_badarg(env);
    return enif_make_tuple2(env, enif_make_uint64(env, p->nauthors), int8_param(env, p->authors, p->nauthors));
}

static size_t int_len(int64_t v) {
    uint64_t u = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    size_t n = v < 0 ? 2 : 1;
    while (u >= 10) { u /= 10; n++; }
    return n;
}

static int has(const Map *m, int64_t viewer, int64_t x) {
    return viewer != 0 && map_get(m, (uint64_t)viewer, (uint64_t)x) >= 0;
}

static void put_piece(Out *o, const Plan *p, Piece x) { put(o, p->text.bin.data + x.off, x.len); }

static void put_flag(Out *o, int b) { put_lit(o, b ? "true" : "false"); }

static const char LIST_OPEN[] = "{\"articles\":[", LIST_COUNT[] = "],\"articlesCount\":",
                  ARTICLE_OPEN[] = "{\"article\":", COMMENTS_OPEN[] = "{\"comments\":[";

/* One request's body: a binary, nil (no such article) or fallback (something it needs is missing). */
static ERL_NIF_TERM plan_body(ErlNifEnv *env, Plan *p, int k, int64_t slot, int64_t viewer) {
    Slot *s = slot >= 0 && (size_t)slot < p->nslots[k] ? p->slots[k] + slot : NULL;
    if (!s || !s->present) return k == K_SLUG || k == K_COMMENTS ? atom_nil : atom_fallback;
    Out o;
    size_t size;
    if (k == K_SLUG) {
        if (!s->full) return atom_fallback;
        int fav = has(&p->favs, viewer, s->n), fol = has(&p->follows, viewer, s->author);
        size = sizeof ARTICLE_OPEN - 1 + s->a.len + (fav ? 4 : 5) + s->b.len + (fol ? 4 : 5) + s->c.len + 1;
        if (!start(env, &o, size)) return enif_make_badarg(env);
        put_lit(&o, ARTICLE_OPEN);
        put_piece(&o, p, s->a);
        put_flag(&o, fav);
        put_piece(&o, p, s->b);
        put_flag(&o, fol);
        put_piece(&o, p, s->c);
        put_char(&o, '}');
    } else if (k == K_COMMENTS) {
        size = sizeof COMMENTS_OPEN - 1 + 2 + (s->count ? s->count - 1 : 0);
        for (size_t i = 0; i < s->count; i++) {
            const Com *c = p->coms + s->first + i;
            size += c->a.len + (has(&p->follows, viewer, c->author) ? 4 : 5) + c->c.len;
        }
        if (!start(env, &o, size)) return enif_make_badarg(env);
        put_lit(&o, COMMENTS_OPEN);
        for (size_t i = 0; i < s->count; i++) {
            const Com *c = p->coms + s->first + i;
            if (i) put_char(&o, ',');
            put_piece(&o, p, c->a);
            put_flag(&o, has(&p->follows, viewer, c->author));
            put_piece(&o, p, c->c);
        }
        put_lit(&o, "]}");
    } else {
        int feed = k == K_FEED;
        size = sizeof LIST_OPEN - 1 + sizeof LIST_COUNT - 1 + int_len(s->n) + 1 + (s->count ? s->count - 1 : 0);
        for (size_t i = 0; i < s->count; i++) {
            int64_t id = p->pages[s->first + i];
            int32_t ai = map_get(&p->art_of, (uint64_t)id, 0);
            if (ai < 0) return atom_fallback;
            const Art *a = p->arts + ai;
            /* a feed's authors were reached through the viewer's follows (the single statement says true) */
            size += a->a.len + (has(&p->favs, viewer, id) ? 4 : 5) + a->b.len +
                    (feed || has(&p->follows, viewer, a->author) ? 4 : 5) + a->c.len;
        }
        if (!start(env, &o, size)) return enif_make_badarg(env);
        put_lit(&o, LIST_OPEN);
        for (size_t i = 0; i < s->count; i++) {
            int64_t id = p->pages[s->first + i];
            const Art *a = p->arts + map_get(&p->art_of, (uint64_t)id, 0);
            if (i) put_char(&o, ',');
            put_piece(&o, p, a->a);
            put_flag(&o, has(&p->favs, viewer, id));
            put_piece(&o, p, a->b);
            put_flag(&o, feed || has(&p->follows, viewer, a->author));
            put_piece(&o, p, a->c);
        }
        put_lit(&o, LIST_COUNT);
        put_int(&o, s->n);
        put_char(&o, '}');
    }
    if (o.ok && o.len != size) { /* the sizes above must be exact */
        enif_release_binary(&o.bin);
        return enif_make_badarg(env);
    }
    return finish(env, &o, 0);
}

/* plan_bodies(Plan, [{Ref, Kind, Slot, Viewer}]) -> [{Ref, {ok, Body | nil}} | {Ref, fallback}], in order: the
 * messages that answer the requests (Kind 0-6 as plan_add's tables). */
static ERL_NIF_TERM plan_bodies(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    Plan *p = plan_of(env, argv[0]);
    unsigned n;
    if (!p || !enif_get_list_length(env, argv[1], &n)) return enif_make_badarg(env);
    ERL_NIF_TERM *out = enif_alloc((n ? n : 1) * sizeof *out);
    if (!out) return enif_make_badarg(env);
    ERL_NIF_TERM head, list = argv[1];
    unsigned i = 0;
    while (enif_get_list_cell(env, list, &head, &list)) {
        const ERL_NIF_TERM *t;
        int arity, k;
        ErlNifSInt64 slot, viewer;
        if (!enif_get_tuple(env, head, &arity, &t) || arity != 4 || !enif_get_int(env, t[1], &k) || k < 0 ||
            k >= KINDS || !enif_get_int64(env, t[2], &slot) || !enif_get_int64(env, t[3], &viewer)) {
            enif_free(out);
            return enif_make_badarg(env);
        }
        ERL_NIF_TERM body = plan_body(env, p, k, slot, viewer), exc;
        if (enif_has_pending_exception(env, &exc)) {
            enif_free(out);
            return exc;
        }
        out[i++] = enif_make_tuple2(env, t[0], body == atom_fallback ? body : enif_make_tuple2(env, atom_ok, body));
    }
    ERL_NIF_TERM res = enif_make_list_from_array(env, out, i);
    enif_free(out);
    return res;
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    plan_type = enif_open_resource_type(env, NULL, "conduit_plan", plan_dtor, ERL_NIF_RT_CREATE, NULL);
    atom_ok = enif_make_atom(env, "ok");
    atom_nil = enif_make_atom(env, "nil");
    atom_fallback = enif_make_atom(env, "fallback");
    atom_encoded = enif_make_atom(env, "encoded");
    return plan_type ? 0 : 1;
}

static ErlNifFunc funcs[] = {
    {"list", 1, render_list, 0},
    {"article", 1, render_article, 0},
    {"comments", 1, render_comments, 0},
    {"profile", 1, render_profile, 0},
    {"tags", 1, render_tags, 0},
    {"article_parts", 2, render_article_parts, 0},
    {"comment_parts", 1, render_comment_parts, 0},
    {"plan_article", 2, render_plan_article, 0},
    {"plan_comment", 1, render_plan_comment, 0},
    {"plan_new", 0, plan_new, 0},
    {"plan_add", 4, plan_add, 0},
    {"plan_ids", 2, plan_ids, 0},
    {"plan_authors", 1, plan_authors, 0},
    {"plan_bodies", 2, plan_bodies, 0},
};

ERL_NIF_INIT(Elixir.Conduit.Render.Nif, funcs, load, NULL, NULL, NULL)
