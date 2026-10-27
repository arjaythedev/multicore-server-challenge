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
    put_lit(o, v[0] ? "true" : "false");
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
    o->ok = enif_alloc_binary(cap, &o->bin);
    return o->ok;
}

static ERL_NIF_TERM finish(ErlNifEnv *env, Out *o, int bad) {
    if (bad || !o->ok) {
        if (o->ok) enif_release_binary(&o->bin);
        return enif_make_badarg(env);
    }
    if (!enif_realloc_binary(&o->bin, o->len)) {
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
            put_lit(&o, "{\"id\":");
            put_int_col(&o, &r);
            const uint8_t *body; size_t body_n;
            col(&r, &body, &body_n);
            if (!body) r.bad = 1;
            put_lit(&o, ",\"createdAt\":");
            put_ts_col(&o, &r);
            put_lit(&o, ",\"updatedAt\":");
            put_ts_col(&o, &r);
            put_lit(&o, ",\"body\":");
            if (body) put_str(&o, body, body_n);
            put_lit(&o, ",\"author\":");
            put_profile(&o, &r);
            put_char(&o, '}');
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

static ErlNifFunc funcs[] = {
    {"list", 1, render_list, 0},
    {"article", 1, render_article, 0},
    {"comments", 1, render_comments, 0},
    {"profile", 1, render_profile, 0},
    {"tags", 1, render_tags, 0},
};

ERL_NIF_INIT(Elixir.Conduit.Render.Nif, funcs, NULL, NULL, NULL, NULL)
