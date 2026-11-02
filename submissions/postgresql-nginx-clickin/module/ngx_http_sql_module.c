/*
 * ngx_http_sql_module: answer an HTTP request with the result of SQL statements.
 *
 * This module knows nothing about the Conduit API. nginx.conf maps a method on a location to a list of .sql files
 * and names the request values they may use:
 *
 *     location ~ ^/api/articles/(?<slug>[^/]+)$ {
 *         sql GET auth.sql,article_get.sql  authorization=$http_authorization secret=env:JWT_SECRET slug=$slug;
 *     }
 *
 * The files run in order, on one Postgres connection, inside one task on nginx's thread pool. SQL refers to
 * values by name (:slug); a value that is absent (no header, no query argument) is NULL. Every column of a
 * statement's first row becomes a value too, for the statements after it. The first row with a non-NULL
 * "status" column is the response: that status, with the "body" column as the JSON body (NULL = empty).
 *
 * Postgres can't do bcrypt here (no extensions), so two column names ask this module for it:
 *   bcrypt_password            -> hashed with bcrypt cost 10 into the value bcrypt_hash (NULL stays NULL)
 *   check_password, check_hash -> compared with bcrypt; a mismatch answers 401
 * Everything else (routing inside a location, JWT, validation, status codes, JSON) is in the SQL files.
 */
#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <ngx_thread_pool.h>

#include <crypt.h>
#include <libpq-fe.h>

#define SQL_MAX_STEPS   16
#define SQL_MAX_VALUES  64

static const char ERR_401[] = "{\"errors\":{\"body\":[\"invalid email or password\"]}}";
static const char ERR_422_DUP[] = "{\"errors\":{\"body\":[\"has already been taken\"]}}";
static const char ERR_422_JSON[] = "{\"errors\":{\"body\":[\"invalid request body\"]}}";
static const char ERR_500[] = "{\"errors\":{\"body\":[\"internal server error\"]}}";
static const char ERR_404[] = "{\"errors\":{\"body\":[\"not found\"]}}";

/* One prepared statement: SQL with :names rewritten to $n, and the name of each $n. */
typedef struct {
    char        *sql;
    char        *names[SQL_MAX_VALUES];
    int          nparams;
} sql_stmt_t;

/* One request value: name=$var, name=@$var (URL-decoded query argument), name=env:VAR, or name=literal. */
typedef struct {
    ngx_str_t    name;
    ngx_int_t    index;       /* variable index, or NGX_ERROR for a literal */
    ngx_uint_t   unescape;
    ngx_str_t    literal;
} sql_param_t;

typedef struct {
    ngx_uint_t   method;      /* NGX_HTTP_GET, ... */
    ngx_uint_t   steps[SQL_MAX_STEPS];
    ngx_uint_t   nsteps;
    ngx_array_t  params;      /* sql_param_t */
} sql_route_t;

typedef struct {
    ngx_str_t    dir;
    ngx_array_t *stmts;       /* sql_stmt_t, shared by every route */
    ngx_thread_pool_t *pool;
} sql_main_conf_t;

typedef struct {
    ngx_array_t *routes;      /* sql_route_t */
} sql_loc_conf_t;

/* A task on the thread pool: request values in, response out. Only malloc() inside the thread. */
typedef struct {
    ngx_http_request_t *r;
    sql_route_t        *route;
    char               *names[SQL_MAX_VALUES];
    char               *values[SQL_MAX_VALUES];
    ngx_uint_t          nvalues;   /* names and values are malloc()'d */
    ngx_int_t           status;
    char               *body;      /* malloc() */
    size_t              body_len;
} sql_task_ctx_t;

static ngx_int_t ngx_http_sql_init(ngx_conf_t *cf);
static void *ngx_http_sql_create_main_conf(ngx_conf_t *cf);
static void *ngx_http_sql_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_sql_dir(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_sql_route(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);

static ngx_command_t ngx_http_sql_commands[] = {
    { ngx_string("sql_dir"), NGX_HTTP_MAIN_CONF | NGX_CONF_TAKE1, ngx_http_sql_dir,
      NGX_HTTP_MAIN_CONF_OFFSET, 0, NULL },
    { ngx_string("sql"), NGX_HTTP_LOC_CONF | NGX_CONF_2MORE, ngx_http_sql_route,
      NGX_HTTP_LOC_CONF_OFFSET, 0, NULL },
    ngx_null_command
};

static ngx_http_module_t ngx_http_sql_module_ctx = {
    NULL, ngx_http_sql_init,
    ngx_http_sql_create_main_conf, NULL,
    NULL, NULL,
    ngx_http_sql_create_loc_conf, NULL
};

ngx_module_t ngx_http_sql_module = {
    NGX_MODULE_V1, &ngx_http_sql_module_ctx, ngx_http_sql_commands, NGX_HTTP_MODULE,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NGX_MODULE_V1_PADDING
};

/* ---- configuration --------------------------------------------------------------------------------------- */

static void *
ngx_http_sql_create_main_conf(ngx_conf_t *cf)
{
    sql_main_conf_t *mcf = ngx_pcalloc(cf->pool, sizeof(sql_main_conf_t));

    if (mcf == NULL) {
        return NULL;
    }
    mcf->stmts = ngx_array_create(cf->pool, 32, sizeof(sql_stmt_t));
    return mcf->stmts ? mcf : NULL;
}

static void *
ngx_http_sql_create_loc_conf(ngx_conf_t *cf)
{
    return ngx_pcalloc(cf->pool, sizeof(sql_loc_conf_t));
}

static char *
ngx_http_sql_dir(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    sql_main_conf_t *mcf = conf;
    ngx_str_t       *v = cf->args->elts;

    mcf->dir = v[1];
    return NGX_CONF_OK;
}

static char *
read_file(ngx_conf_t *cf, ngx_str_t *dir, u_char *name, size_t len)
{
    char  path[1024], *buf;
    FILE *f;
    long  n;

    if (dir->len + len + 2 > sizeof(path)) {
        return NULL;
    }
    ngx_sprintf((u_char *) path, "%V/%*s%Z", dir, len, name);
    f = fopen(path, "rb");
    if (f == NULL) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, ngx_errno, "sql: cannot open \"%s\"", path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = ngx_pnalloc(cf->pool, n + 1);
    if (buf == NULL || fread(buf, 1, n, f) != (size_t) n) {
        fclose(f);
        return NULL;
    }
    fclose(f);
    buf[n] = '\0';
    return buf;
}

/*
 * Load a .sql file: expand {{fragment}} (the file fragment.sql, pasted in place), then turn each :name outside
 * string literals and comments into $n. "::type" casts are left alone.
 */
static ngx_int_t
load_stmt(ngx_conf_t *cf, sql_main_conf_t *mcf, u_char *file, size_t flen, ngx_uint_t *out)
{
    sql_stmt_t *st;
    char       *src, *p, *e;
    u_char     *dst, *d;
    size_t      cap;
    char        expanded[65536];
    size_t      xl = 0;

    src = read_file(cf, &mcf->dir, file, flen);
    if (src == NULL) {
        return NGX_ERROR;
    }

    /* {{fragment}}, until none is left (fragments may use fragments) */
    for (int depth = 0; ; depth++) {
    xl = 0;
    for (p = src; *p; ) {
        if (p[0] == '{' && p[1] == '{' && (e = strstr(p, "}}")) != NULL) {
            char  name[256];
            char *frag;
            size_t fl, nl = e - (p + 2);

            if (nl + 5 > sizeof(name)) {
                return NGX_ERROR;
            }
            ngx_sprintf((u_char *) name, "%*s.sql%Z", nl, p + 2);
            frag = read_file(cf, &mcf->dir, (u_char *) name, nl + 4);
            if (frag == NULL) {
                return NGX_ERROR;
            }
            fl = strlen(frag);
            while (fl > 0 && (frag[fl - 1] == '\n' || frag[fl - 1] == ' ')) {
                fl--;
            }
            if (xl + fl >= sizeof(expanded)) {
                return NGX_ERROR;
            }
            memcpy(expanded + xl, frag, fl);
            xl += fl;
            p = e + 2;
        } else {
            if (xl + 1 >= sizeof(expanded)) {
                return NGX_ERROR;
            }
            expanded[xl++] = *p++;
        }
    }
    expanded[xl] = '\0';
    if (strstr(expanded, "{{") == NULL) {
        break;
    }
    if (depth == 8) {
        return NGX_ERROR;
    }
    src = ngx_pnalloc(cf->pool, xl + 1);
    if (src == NULL) {
        return NGX_ERROR;
    }
    ngx_memcpy(src, expanded, xl + 1);
    }

    st = ngx_array_push(mcf->stmts);
    if (st == NULL) {
        return NGX_ERROR;
    }
    ngx_memzero(st, sizeof(*st));
    cap = xl * 2 + 16;
    dst = ngx_pnalloc(cf->pool, cap);
    if (dst == NULL) {
        return NGX_ERROR;
    }
    d = dst;
    for (p = expanded; *p; ) {
        if (p[0] == '\'') {                              /* 'string literal' with '' escapes */
            *d++ = *p++;
            while (*p && !(p[0] == '\'' && p[1] != '\'')) {
                if (p[0] == '\'') {
                    *d++ = *p++;
                }
                *d++ = *p++;
            }
            if (*p) {
                *d++ = *p++;
            }
        } else if (p[0] == '-' && p[1] == '-') {         /* -- comment: dropped */
            while (*p && *p != '\n') {
                p++;
            }
        } else if (p[0] == ':' && p[1] == ':') {         /* ::cast */
            *d++ = *p++;
            *d++ = *p++;
        } else if (p[0] == ':' && (p[1] == '_' || (p[1] >= 'a' && p[1] <= 'z'))) {
            char   *s = ++p;
            size_t  n;
            int     i;

            while (*p == '_' || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9')) {
                p++;
            }
            n = p - s;
            for (i = 0; i < st->nparams; i++) {
                if (strlen(st->names[i]) == n && strncmp(st->names[i], s, n) == 0) {
                    break;
                }
            }
            if (i == st->nparams) {
                if (st->nparams == SQL_MAX_VALUES) {
                    return NGX_ERROR;
                }
                st->names[i] = ngx_pnalloc(cf->pool, n + 1);
                ngx_memcpy(st->names[i], s, n);
                st->names[i][n] = '\0';
                st->nparams++;
            }
            d = ngx_sprintf(d, "$%d", i + 1);
        } else {
            *d++ = *p++;
        }
    }
    *d = '\0';
    st->sql = (char *) dst;
    *out = mcf->stmts->nelts - 1;
    return NGX_OK;
}

static ngx_int_t ngx_http_sql_handler(ngx_http_request_t *r);

/* sql METHOD a.sql,b.sql name=value ... */
static char *
ngx_http_sql_route(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    sql_loc_conf_t           *lcf = conf;
    sql_main_conf_t          *mcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_sql_module);
    ngx_http_core_loc_conf_t *clcf;
    ngx_str_t                *v = cf->args->elts;
    sql_route_t              *route;
    u_char                   *p, *start, *end;
    ngx_uint_t                i;
    static const struct { const char *name; ngx_uint_t m; } methods[] = {
        { "GET", NGX_HTTP_GET }, { "POST", NGX_HTTP_POST }, { "PUT", NGX_HTTP_PUT }, { "DELETE", NGX_HTTP_DELETE },
    };

    if (mcf->dir.len == 0) {
        return "needs sql_dir before it";
    }
    if (lcf->routes == NULL) {
        lcf->routes = ngx_array_create(cf->pool, 4, sizeof(sql_route_t));
        if (lcf->routes == NULL) {
            return NGX_CONF_ERROR;
        }
    }
    route = ngx_array_push(lcf->routes);
    if (route == NULL) {
        return NGX_CONF_ERROR;
    }
    ngx_memzero(route, sizeof(*route));
    for (i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        if (ngx_strcmp(v[1].data, methods[i].name) == 0) {
            route->method = methods[i].m;
        }
    }
    if (route->method == 0) {
        return "unknown method";
    }

    for (start = v[2].data, end = v[2].data + v[2].len; start < end; start = p + 1) {
        p = ngx_strlchr(start, end, ',');
        if (p == NULL) {
            p = end;
        }
        if (route->nsteps == SQL_MAX_STEPS
            || load_stmt(cf, mcf, start, p - start, &route->steps[route->nsteps]) != NGX_OK)
        {
            return "cannot load SQL";
        }
        route->nsteps++;
    }

    if (ngx_array_init(&route->params, cf->pool, cf->args->nelts, sizeof(sql_param_t)) != NGX_OK) {
        return NGX_CONF_ERROR;
    }
    for (i = 3; i < cf->args->nelts; i++) {
        sql_param_t *pm = ngx_array_push(&route->params);
        ngx_str_t    val;

        p = ngx_strlchr(v[i].data, v[i].data + v[i].len, '=');
        if (p == NULL) {
            return "params are name=value";
        }
        pm->name.data = v[i].data;
        pm->name.len = p - v[i].data;
        val.data = p + 1;
        val.len = v[i].data + v[i].len - val.data;
        pm->index = NGX_ERROR;
        if (val.len > 0 && val.data[0] == '@') {
            pm->unescape = 1;
            val.data++;
            val.len--;
        }
        if (val.len > 1 && val.data[0] == '$') {
            val.data++;
            val.len--;
            pm->index = ngx_http_get_variable_index(cf, &val);
            if (pm->index == NGX_ERROR) {
                return NGX_CONF_ERROR;
            }
        } else if (val.len > 4 && ngx_strncmp(val.data, "env:", 4) == 0) {
            char *name = ngx_pnalloc(cf->pool, val.len - 3), *env;

            ngx_memcpy(name, val.data + 4, val.len - 4);
            name[val.len - 4] = '\0';
            env = getenv(name);
            if (env == NULL) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0, "sql: environment variable %s is not set", name);
                return NGX_CONF_ERROR;
            }
            pm->literal.data = (u_char *) env;
            pm->literal.len = ngx_strlen(env);
        } else {
            pm->literal = val;
        }
    }

    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_sql_handler;
    return NGX_CONF_OK;
}

static ngx_int_t
ngx_http_sql_init(ngx_conf_t *cf)
{
    static ngx_str_t  name = ngx_string("sql");
    sql_main_conf_t  *mcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_sql_module);

    mcf->pool = ngx_thread_pool_add(cf, &name);   /* sized by "thread_pool sql threads=N" in nginx.conf */
    return mcf->pool ? NGX_OK : NGX_ERROR;
}

/* ---- the thread: Postgres and bcrypt ---------------------------------------------------------------------- */

static __thread PGconn  *tl_conn;
static __thread u_char  *tl_prepared;           /* one flag per statement, for tl_conn */

static PGconn *
thread_conn(ngx_uint_t nstmts, ngx_log_t *log)
{
    PGresult *res;

    if (tl_conn != NULL && PQstatus(tl_conn) == CONNECTION_OK) {
        return tl_conn;
    }
    if (tl_conn != NULL) {
        PQfinish(tl_conn);
    }
    tl_conn = PQconnectdb(getenv("DATABASE_URL"));
    if (PQstatus(tl_conn) != CONNECTION_OK) {
        ngx_log_error(NGX_LOG_ERR, log, 0, "sql: connect: %s", PQerrorMessage(tl_conn));
        PQfinish(tl_conn);
        tl_conn = NULL;
        return NULL;
    }
    /* Generic plans: request values stay parameters, so a CASE guard really guards what's behind it. */
    res = PQexec(tl_conn, "SET plan_cache_mode = force_generic_plan; SET jit = off");
    PQclear(res);
    free(tl_prepared);
    tl_prepared = calloc(nstmts, 1);
    return tl_conn;
}

static void
set_value(sql_task_ctx_t *t, const char *name, const char *value)
{
    ngx_uint_t i;

    for (i = 0; i < t->nvalues; i++) {
        if (strcmp(t->names[i], name) == 0) {
            break;
        }
    }
    if (i == t->nvalues) {
        if (t->nvalues == SQL_MAX_VALUES) {
            return;
        }
        t->names[i] = strdup(name);
        t->nvalues++;
    } else {
        free(t->values[i]);
    }
    t->values[i] = value ? strdup(value) : NULL;
}

static const char *
get_value(sql_task_ctx_t *t, const char *name)
{
    for (ngx_uint_t i = 0; i < t->nvalues; i++) {
        if (strcmp(t->names[i], name) == 0) {
            return t->values[i];
        }
    }
    return NULL;
}

static void
respond(sql_task_ctx_t *t, ngx_int_t status, const char *body)
{
    t->status = status;
    t->body = body ? strdup(body) : NULL;
    t->body_len = body ? strlen(body) : 0;
}

static char *
bcrypt_hash(const char *password)
{
    char               salt[CRYPT_GENSALT_OUTPUT_SIZE];
    struct crypt_data *cd;
    char              *h, *out = NULL;

    if (crypt_gensalt_rn("$2b$", 10, NULL, 0, salt, sizeof(salt)) == NULL) {
        return NULL;
    }
    cd = calloc(1, sizeof(*cd));
    h = crypt_rn(password, salt, cd, sizeof(*cd));
    if (h != NULL && h[0] != '*') {
        out = strdup(h);
    }
    free(cd);
    return out;
}

static int
bcrypt_check(const char *password, const char *hash)
{
    struct crypt_data *cd = calloc(1, sizeof(*cd));
    char              *h = crypt_rn(password, hash, cd, sizeof(*cd));
    size_t             n = strlen(hash);
    int                ok = 0;

    if (h != NULL && h[0] != '*' && strlen(h) == n) {
        unsigned char diff = 0;

        for (size_t i = 0; i < n; i++) {
            diff |= (unsigned char) (h[i] ^ hash[i]);
        }
        ok = diff == 0;
    }
    free(cd);
    return ok;
}

static void
ngx_http_sql_thread(void *data, ngx_log_t *log)
{
    sql_task_ctx_t  *t = data;
    sql_main_conf_t *mcf = ngx_http_get_module_main_conf(t->r, ngx_http_sql_module);
    sql_stmt_t      *stmts = mcf->stmts->elts;
    PGconn          *c = thread_conn(mcf->stmts->nelts, log);

    if (c == NULL) {
        respond(t, 500, ERR_500);
        return;
    }

    for (ngx_uint_t s = 0; s < t->route->nsteps && t->status == 0; s++) {
        ngx_uint_t   id = t->route->steps[s];
        sql_stmt_t  *st = &stmts[id];
        char         name[16];
        const char  *vals[SQL_MAX_VALUES];
        PGresult    *res;
        int          ok;

        snprintf(name, sizeof(name), "s%lu", (unsigned long) id);
        if (!tl_prepared[id]) {
            res = PQprepare(c, name, st->sql, 0, NULL);
            ok = PQresultStatus(res) == PGRES_COMMAND_OK;
            if (!ok) {
                ngx_log_error(NGX_LOG_ERR, log, 0, "sql: prepare: %s", PQresultErrorMessage(res));
            }
            PQclear(res);
            if (!ok) {
                respond(t, 500, ERR_500);
                break;
            }
            tl_prepared[id] = 1;
        }
        for (int i = 0; i < st->nparams; i++) {
            vals[i] = get_value(t, st->names[i]);
        }
        res = PQexecPrepared(c, name, st->nparams, vals, NULL, NULL, 0);
        switch (PQresultStatus(res)) {
        case PGRES_TUPLES_OK:
            if (PQntuples(res) > 0) {
                for (int f = 0; f < PQnfields(res); f++) {
                    set_value(t, PQfname(res, f), PQgetisnull(res, 0, f) ? NULL : PQgetvalue(res, 0, f));
                }
            }
            break;
        case PGRES_COMMAND_OK:
            break;
        default: {
            const char *state = PQresultErrorField(res, PG_DIAG_SQLSTATE);

            if (state != NULL && strcmp(state, "23505") == 0) {
                respond(t, 422, ERR_422_DUP);                     /* unique violation */
            } else if (state != NULL && strncmp(state, "22", 2) == 0) {
                respond(t, 422, ERR_422_JSON);                    /* data exception: the body isn't JSON */
            } else {
                ngx_log_error(NGX_LOG_ERR, log, 0, "sql: %s: %s", name, PQresultErrorMessage(res));
                respond(t, 500, ERR_500);
            }
        }
        }
        PQclear(res);
        if (t->status != 0) {
            break;
        }

        if (get_value(t, "status") != NULL) {
            respond(t, ngx_atoi((u_char *) get_value(t, "status"), strlen(get_value(t, "status"))),
                    get_value(t, "body"));
            break;
        }
        if (get_value(t, "check_hash") != NULL || get_value(t, "check_password") != NULL) {
            const char *pw = get_value(t, "check_password"), *hash = get_value(t, "check_hash");

            if (pw == NULL || hash == NULL || !bcrypt_check(pw, hash)) {
                respond(t, 401, ERR_401);
                break;
            }
            set_value(t, "check_password", NULL);
            set_value(t, "check_hash", NULL);
        }
        if (get_value(t, "bcrypt_password") != NULL) {
            char *h = bcrypt_hash(get_value(t, "bcrypt_password"));

            if (h == NULL) {
                respond(t, 500, ERR_500);
                break;
            }
            set_value(t, "bcrypt_hash", h);
            set_value(t, "bcrypt_password", NULL);
            free(h);
        }
    }

    if (t->status == 0) {
        ngx_log_error(NGX_LOG_ERR, log, 0, "sql: no statement set a status");
        respond(t, 500, ERR_500);
    }
    if (PQtransactionStatus(c) != PQTRANS_IDLE) {             /* an error inside BEGIN ... COMMIT */
        PQclear(PQexec(c, "ROLLBACK"));
    }
}

/* ---- the event loop side ---------------------------------------------------------------------------------- */

static ngx_int_t
send_response(ngx_http_request_t *r, ngx_int_t status, const char *body, size_t len)
{
    ngx_buf_t   *b;
    ngx_chain_t  out;
    ngx_int_t    rc;

    r->headers_out.status = status;
    ngx_str_set(&r->headers_out.content_type, "application/json");
    r->headers_out.content_type_len = r->headers_out.content_type.len;
    if (status == NGX_HTTP_NO_CONTENT || len == 0) {
        r->header_only = 1;
        r->headers_out.content_length_n = 0;
        if (status == NGX_HTTP_NO_CONTENT) {
            ngx_str_null(&r->headers_out.content_type);
            r->headers_out.content_length_n = -1;
        }
        return ngx_http_send_header(r);
    }
    r->headers_out.content_length_n = len;
    b = ngx_create_temp_buf(r->pool, len);
    if (b == NULL) {
        return NGX_ERROR;
    }
    b->last = ngx_cpymem(b->pos, body, len);
    b->last_buf = (r == r->main);
    b->last_in_chain = 1;
    out.buf = b;
    out.next = NULL;
    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        return rc;
    }
    return ngx_http_output_filter(r, &out);
}

static void
free_task(sql_task_ctx_t *t)
{
    for (ngx_uint_t i = 0; i < t->nvalues; i++) {
        free(t->names[i]);
        free(t->values[i]);
    }
    free(t->body);
}

static void
ngx_http_sql_done(ngx_event_t *ev)
{
    sql_task_ctx_t     *t = ev->data;
    ngx_http_request_t *r = t->r;
    ngx_connection_t   *c = r->connection;
    ngx_int_t           rc;

    rc = send_response(r, t->status, t->body, t->body_len);
    free_task(t);
    ngx_http_finalize_request(r, rc);
    ngx_http_run_posted_requests(c);
}

static void
ngx_http_sql_body_read(ngx_http_request_t *r)
{
    sql_main_conf_t *mcf = ngx_http_get_module_main_conf(r, ngx_http_sql_module);
    sql_loc_conf_t  *lcf = ngx_http_get_module_loc_conf(r, ngx_http_sql_module);
    sql_route_t     *routes = lcf->routes->elts, *route = NULL;
    sql_param_t     *pm;
    ngx_thread_task_t *task;
    sql_task_ctx_t  *t;
    ngx_uint_t       i;

    for (i = 0; i < lcf->routes->nelts; i++) {
        if (routes[i].method == r->method) {
            route = &routes[i];
        }
    }
    if (route == NULL) {
        ngx_http_finalize_request(r, send_response(r, NGX_HTTP_NOT_FOUND, ERR_404, sizeof(ERR_404) - 1));
        return;
    }

    task = ngx_thread_task_alloc(r->pool, sizeof(sql_task_ctx_t));
    if (task == NULL) {
        ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    }
    t = task->ctx;
    t->r = r;
    t->route = route;

    pm = route->params.elts;
    for (i = 0; i < route->params.nelts && i < SQL_MAX_VALUES; i++) {
        ngx_str_t  val = pm[i].literal;
        int        found = 1;
        u_char    *s;
        char      *n;

        if (pm[i].index != NGX_ERROR) {
            ngx_http_variable_value_t *vv = ngx_http_get_indexed_variable(r, pm[i].index);

            found = vv != NULL && !vv->not_found;
            if (found) {
                val.data = vv->data;
                val.len = vv->len;
            }
        }
        n = ngx_pnalloc(r->pool, pm[i].name.len + 1);
        if (n == NULL) {
            ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
            return;
        }
        ngx_memcpy(n, pm[i].name.data, pm[i].name.len);
        n[pm[i].name.len] = '\0';
        if (!found) {
            set_value(t, n, NULL);
            continue;
        }
        s = ngx_pnalloc(r->pool, val.len + 1);
        if (s == NULL) {
            ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
            return;
        }
        if (pm[i].unescape) {                          /* query argument: '+' is a space, then %XX */
            u_char *src = s, *dst = s, *end;

            for (size_t k = 0; k < val.len; k++) {
                s[k] = val.data[k] == '+' ? ' ' : val.data[k];
            }
            ngx_unescape_uri(&dst, &src, val.len, 0);
            end = dst;
            *end = '\0';
            if (ngx_strlen(s) != (size_t) (end - s)) {  /* %00 */
                free_task(t);
                ngx_http_finalize_request(r, send_response(r, 422, ERR_422_JSON, sizeof(ERR_422_JSON) - 1));
                return;
            }
        } else {
            ngx_memcpy(s, val.data, val.len);
            s[val.len] = '\0';
            if (ngx_strlen(s) != val.len) {            /* a NUL byte can't go to Postgres as text */
                free_task(t);
                ngx_http_finalize_request(r, send_response(r, 422, ERR_422_JSON, sizeof(ERR_422_JSON) - 1));
                return;
            }
        }
        set_value(t, n, (char *) s);
    }

    task->handler = ngx_http_sql_thread;
    task->event.data = t;
    task->event.handler = ngx_http_sql_done;
    if (ngx_thread_task_post(mcf->pool, task) != NGX_OK) {
        free_task(t);
        ngx_http_finalize_request(r, NGX_HTTP_SERVICE_UNAVAILABLE);
    }
}

static ngx_int_t
ngx_http_sql_handler(ngx_http_request_t *r)
{
    ngx_int_t rc = ngx_http_read_client_request_body(r, ngx_http_sql_body_read);

    if (rc >= NGX_HTTP_SPECIAL_RESPONSE) {
        return rc;
    }
    return NGX_DONE;
}
