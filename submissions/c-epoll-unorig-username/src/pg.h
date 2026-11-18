// Small PostgreSQL wire client: extended protocol in binary, pipelined, no RowDescription.
#pragma once
#include "common.h"

typedef struct {
  const char *name, *sql;
} pg_stmt;

typedef struct {
  int fd;
  buf_t out;
  size_t bind_start, params_start;
} pg_t;

typedef struct {
  const char *p, *end;
  bool lost;        // connection failed: results unknown
  bool error;       // the server reported an error; the pipeline was aborted
  char sqlstate[6];
  char constraint[64];
} pg_res;

bool pg_connect(pg_t *c, const char *const *settings, int nsettings, const pg_stmt *st, int nst);
void pg_close(pg_t *c);
void pg_bind(pg_t *c, const char *stmt, int nparams);
void pg_null(pg_t *c);
void pg_i64(pg_t *c, int64_t v);
void pg_text(pg_t *c, const char *s, size_t l);
void pg_i64arr(pg_t *c, const int64_t *v, int n);
void pg_textarr(pg_t *c, const char *const *s, const uint32_t *l, int n);
void pg_bind_end(pg_t *c);
// Sends what is queued plus Sync, reads to ReadyForQuery into the arena. false: see res.lost / res.error.
bool pg_exchange(pg_t *c, arena_t *a, pg_res *res);
#define PG_MAXCOL 16
typedef struct {
  const char *v[PG_MAXCOL];
  int32_t l[PG_MAXCOL];
  int n;
} pg_row;
// 1 = a row; 0 = this statement finished.
int pg_next(pg_res *r, pg_row *row);

static inline int64_t be64(const char *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return (int64_t)__builtin_bswap64(v);
}
static inline int32_t be32s(const char *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return (int32_t)__builtin_bswap32(v);
}
// A binary int8[] value: returns the count, and the elements via be64(data + i*12 + 4).
static inline int pg_arr_i64(const char *p, int32_t l, const char **data) {
  if (l < 12 || be32s(p) == 0) {
    *data = NULL;
    return 0;
  }
  int n = be32s(p + 12);
  *data = p + 20;
  return n;
}
#define PG_ARR_AT(d, i) be64((d) + (size_t)(i) * 12 + 4)
extern char *pg_url;
