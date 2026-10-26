/* PostgreSQL frontend/backend protocol 3.0, as pure byte work: building messages into a buffer, splitting received
 * bytes into messages, reading binary rows, and the startup/SCRAM-SHA-256 exchange. No I/O here; the event loop
 * (or the blocking startup code) moves the bytes.
 *
 * Every statement is a named prepared statement, every parameter and result column is in binary format, and a
 * batch of Bind/Execute pairs ends with one Sync, so a batch is one implicit transaction. */
#pragma once
#include "buf.h"

/* Type OIDs (pg_type.dat). */
enum {
    OID_BOOL = 16,
    OID_INT8 = 20,
    OID_INT2 = 21,
    OID_INT4 = 23,
    OID_TEXT = 25,
    OID_VARCHAR = 1043,
    OID_TIMESTAMPTZ = 1184,
    OID_INT4_ARRAY = 1007,
    OID_TEXT_ARRAY = 1009,
    OID_INT8_ARRAY = 1016,
};

/* ---- building frontend messages ---- */

void pg_startup(struct buf *b, const char *user, const char *database);
void pg_query(struct buf *b, const char *sql);  /* simple query protocol, for SET at startup */
void pg_parse(struct buf *b, const char *name, const char *sql, uint16_t nparams, const uint32_t *oids);
void pg_describe_stmt(struct buf *b, const char *name);
void pg_execute(struct buf *b);                 /* the unnamed portal, all rows */
void pg_sync(struct buf *b);
void pg_terminate(struct buf *b);

/* A Bind message for the unnamed portal: parameters appended one by one, all binary, all results binary. */
struct pg_bind {
    struct buf *b;
    size_t msg_at, count_at;
    uint16_t n;
};
void pg_bind_begin(struct pg_bind *pb, struct buf *b, const char *stmt);
void pg_bind_null(struct pg_bind *pb);
void pg_bind_i64(struct pg_bind *pb, int64_t v);
void pg_bind_i32(struct pg_bind *pb, int32_t v);
void pg_bind_bool(struct pg_bind *pb, bool v);
void pg_bind_text(struct pg_bind *pb, const char *s, size_t n);
/* One-dimensional arrays without NULLs. */
void pg_bind_i64_array(struct pg_bind *pb, const int64_t *v, uint32_t n);
void pg_bind_text_array(struct pg_bind *pb, const char *const *s, const uint32_t *lens, uint32_t n);
/* Arrays built element by element: begin, then one element call per item, then end. */
void pg_bind_array_begin(struct pg_bind *pb, uint32_t elem_oid, size_t *at);
void pg_bind_array_i64(struct pg_bind *pb, int64_t v);
void pg_bind_array_i32(struct pg_bind *pb, int32_t v);
void pg_bind_array_text(struct pg_bind *pb, const char *s, size_t n);
void pg_bind_array_null(struct pg_bind *pb);
void pg_bind_array_end(struct pg_bind *pb, size_t at, uint32_t count, bool has_null);
void pg_bind_end(struct pg_bind *pb);

/* ---- reading backend messages ---- */

struct pg_msg {
    char type;
    uint32_t len;           /* body length */
    const uint8_t *body;
};

/* If p[0..n) starts with a complete message, fills m and returns its total size; otherwise returns 0.
 * Returns -1 for a length that cannot be valid (protocol error). */
ptrdiff_t pg_next(const uint8_t *p, size_t n, struct pg_msg *m);

/* ErrorResponse / NoticeResponse fields. */
struct pg_error {
    char sqlstate[6];
    const char *message;    /* points into the message body (NUL-terminated there) */
};
void pg_parse_error(const struct pg_msg *m, struct pg_error *e);

/* DataRow columns, in order. pg_col returns the value length, -1 for NULL, or -2 if the row is malformed. */
struct pg_row {
    const uint8_t *p, *end;
    uint16_t ncols;
};
bool pg_row_init(struct pg_row *r, const struct pg_msg *m);
static inline int32_t pg_col(struct pg_row *r, const uint8_t **val) {
    if (unlikely(r->end - r->p < 4)) return -2;
    int32_t len = (int32_t)load_be32(r->p);
    r->p += 4;
    if (len < 0) return -1;
    if (unlikely(r->end - r->p < len)) return -2;
    *val = r->p;
    r->p += len;
    return len;
}

static inline int64_t pg_i64(const uint8_t *v) { return (int64_t)load_be64(v); }
static inline int32_t pg_i32(const uint8_t *v) { return (int32_t)load_be32(v); }

/* Binary one-dimensional array elements, in order. */
struct pg_array {
    const uint8_t *p, *end;
    uint32_t n;             /* element count */
    uint32_t elem_oid;
};
bool pg_array_init(struct pg_array *a, const uint8_t *v, int32_t len);
/* Next element: its length, -1 for NULL, -2 if malformed. */
static inline int32_t pg_array_next(struct pg_array *a, const uint8_t **val) {
    struct pg_row r = {a->p, a->end, 0};
    int32_t len = pg_col(&r, val);
    a->p = r.p;
    return len;
}

/* ---- connection startup and authentication ---- */

struct pg_auth {
    const char *user, *password;
    int state;
    char client_first_bare[96];
    size_t cfb_len;
    char client_nonce[48];
    uint8_t server_signature[32];
    char error[160];        /* set when pg_auth_step returns PG_AUTH_FAILED */
};

enum { PG_AUTH_MORE, PG_AUTH_READY, PG_AUTH_FAILED };

/* nonce_random: 18 random bytes for the SCRAM client nonce. */
void pg_auth_init(struct pg_auth *a, const char *user, const char *password, const uint8_t nonce_random[18]);
/* Feeds one backend message received during startup; may append a reply to out. Returns PG_AUTH_READY once the
 * server sends ReadyForQuery after a successful authentication. */
int pg_auth_step(struct pg_auth *a, const struct pg_msg *m, struct buf *out);

/* ---- connection strings ---- */

struct pg_url {
    char host[128], port[8], user[64], password[128], dbname[64];
};
/* postgres://user:password@host:port/dbname[?...] (also postgresql://). Missing parts get libpq's defaults. */
bool pg_url_parse(const char *url, struct pg_url *u);
