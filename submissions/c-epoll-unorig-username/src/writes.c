// Group commit: each write thread takes every waiting write (up to 128) and sends them with one Sync, so they share one
// transaction and one WAL flush. Answers go out only after ReadyForQuery. If any statement fails Postgres rolls the
// group back, and each write is retried alone so one bad request can't fail the others. A connection lost mid-group
// fails those writes with 500: the commit is unknown, and nothing is claimed.
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

#include "pg.h"

static const pg_stmt WRITE_STMTS[] = {
    {"w_register", "INSERT INTO users (username, email, password_hash) VALUES ($1::text, $2::text, $3::text)"
                   " ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image"},
    {"w_user", "UPDATE users SET email = COALESCE($2::text, email), username = COALESCE($3::text, username),"
               " password_hash = COALESCE($4::text, password_hash), bio = COALESCE($5::text, bio), image = COALESCE($6::text, image)"
               " WHERE id = $1::int8 RETURNING id, username, email, bio, image"},
    {"w_follow", "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2::text),"
                 " w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1::int8, id FROM t ON CONFLICT DO NOTHING)"
                 " SELECT id, username, bio, image FROM t"},
    {"w_unfollow", "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2::text),"
                   " w AS (DELETE FROM follows WHERE follower_id = $1::int8 AND followee_id IN (SELECT id FROM t))"
                   " SELECT id, username, bio, image FROM t"},
    {"w_fav", "WITH a AS (SELECT id FROM articles WHERE slug = $2::text),"
              " w AS (INSERT INTO favorites (user_id, article_id) SELECT $1::int8, id FROM a ON CONFLICT DO NOTHING) SELECT id FROM a"},
    {"w_unfav", "WITH a AS (SELECT id FROM articles WHERE slug = $2::text),"
                " w AS (DELETE FROM favorites WHERE user_id = $1::int8 AND article_id IN (SELECT id FROM a)) SELECT id FROM a"},
    {"w_article", "INSERT INTO articles (id, slug, author_id, title, description, body)"
                  " SELECT n.id, $5::text || '-' || n.id, $1::int8, $2::text, $3::text, $4::text"
                  " FROM (SELECT nextval('articles_id_seq'::regclass) AS id) n RETURNING id"},
    {"w_tags", "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ORDER BY 1 ON CONFLICT (name) DO NOTHING"},
    {"w_atags", "INSERT INTO article_tags (article_id, tag_id) SELECT currval('articles_id_seq'::regclass), t.id FROM tags t WHERE t.name = ANY($1::text[])"},
    {"w_put", "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1::text),"
              " w AS (UPDATE articles a SET title = COALESCE($2::text, a.title), description = COALESCE($3::text, a.description),"
              " body = COALESCE($4::text, a.body), updated_at = now(),"
              " slug = CASE WHEN $5::text IS NULL THEN a.slug ELSE $5::text || '-' || a.id END"
              " FROM t WHERE a.id = t.id AND t.author_id = $6::int8) SELECT id, author_id FROM t"},
    {"w_del", "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1::text),"
              " w AS (DELETE FROM articles WHERE id IN (SELECT id FROM t WHERE author_id = $2::int8)) SELECT author_id FROM t"},
    {"w_comment", "WITH c AS (INSERT INTO comments (article_id, author_id, body)"
                  " SELECT id, $2::int8, $3::text FROM articles WHERE slug = $1::text RETURNING id, created_at, updated_at, body, author_id)"
                  " SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id"},
    {"w_cdel", "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1::int8 AND a.slug = $2::text),"
               " w AS (DELETE FROM comments WHERE id IN (SELECT id FROM t WHERE author_id = $3::int8)) SELECT author_id FROM t"},
};
static const char *const WSET[] = {"SET plan_cache_mode = force_generic_plan", "SET jit = off", "SET max_parallel_workers_per_gather = 0", "SET TimeZone = 'UTC'"};
#define NWSET (int)(sizeof WSET / sizeof *WSET)
#define NWST (int)(sizeof WRITE_STMTS / sizeof *WRITE_STMTS)
#define GROUP 128

static void opt(pg_t *c, const char *s, uint32_t l) {
  if (s) pg_text(c, s, l);
  else pg_null(c);
}

static void bind_one(pg_t *c, job *j) {
  switch (j->kind) {
    case W_REGISTER:
      pg_bind(c, "w_register", 3);
      pg_text(c, j->s1, j->l1); pg_text(c, j->s2, j->l2); pg_text(c, j->s4, j->l4);
      pg_bind_end(c);
      break;
    case W_USER:
      pg_bind(c, "w_user", 6);
      pg_i64(c, j->viewer); opt(c, j->s1, j->l1); opt(c, j->s2, j->l2); opt(c, j->s4, j->l4); opt(c, j->s5, j->l5); opt(c, j->s6, j->l6);
      pg_bind_end(c);
      break;
    case W_FOLLOW: case W_UNFOLLOW:
      pg_bind(c, j->kind == W_FOLLOW ? "w_follow" : "w_unfollow", 2);
      pg_i64(c, j->viewer); pg_text(c, j->s1, j->l1);
      pg_bind_end(c);
      break;
    case W_FAV: case W_UNFAV:
      pg_bind(c, j->kind == W_FAV ? "w_fav" : "w_unfav", 2);
      pg_i64(c, j->viewer); pg_text(c, j->s1, j->l1);
      pg_bind_end(c);
      break;
    case W_ARTICLE:
      pg_bind(c, "w_article", 5);
      pg_i64(c, j->viewer); pg_text(c, j->s1, j->l1); pg_text(c, j->s2, j->l2); pg_text(c, j->s3, j->l3); pg_text(c, j->s4, j->l4);
      pg_bind_end(c);
      if (j->ntags) {
        pg_bind(c, "w_tags", 1); pg_textarr(c, j->tags, j->tag_lens, j->ntags); pg_bind_end(c);
        pg_bind(c, "w_atags", 1); pg_textarr(c, j->tags, j->tag_lens, j->ntags); pg_bind_end(c);
      }
      break;
    case W_ARTICLE_PUT:
      pg_bind(c, "w_put", 6);
      pg_text(c, j->s1, j->l1); opt(c, j->s2, j->l2); opt(c, j->s3, j->l3); opt(c, j->s4, j->l4); opt(c, j->s5, j->l5); pg_i64(c, j->viewer);
      pg_bind_end(c);
      break;
    case W_ARTICLE_DEL:
      pg_bind(c, "w_del", 2);
      pg_text(c, j->s1, j->l1); pg_i64(c, j->viewer);
      pg_bind_end(c);
      break;
    case W_COMMENT:
      pg_bind(c, "w_comment", 3);
      pg_text(c, j->s1, j->l1); pg_i64(c, j->viewer); pg_text(c, j->s2, j->l2);
      pg_bind_end(c);
      break;
    case W_COMMENT_DEL:
      pg_bind(c, "w_cdel", 3);
      pg_i64(c, j->id); pg_text(c, j->s1, j->l1); pg_i64(c, j->viewer);
      pg_bind_end(c);
      break;
  }
}

// Called after the group committed. Consumes j's statements' results and answers (or queues the read that does).
static void finish_one(job *j, pg_res *r, buf_t *O) {
  pg_row row;
  bool has = false;
  int64_t a0 = 0, a1 = 0;
  O->n = 0;
  switch (j->kind) {
    case W_REGISTER: case W_USER: {
      char tok[256];
      while (pg_next(r, &row)) {
        has = true;
        size_t tl = j->token_len;
        const char *t = j->token;
        if (j->kind == W_REGISTER) {
          tl = jwt_issue(be64(row.v[0]), tok);
          t = tok;
        }
        render_user(O, row.v[1], row.l[1], row.v[2], row.l[2], row.v[3], row.l[3], row.v[4], row.l[4], t, tl);
      }
      if (!has) job_error(j, j->kind == W_REGISTER ? 422 : 401, j->kind == W_REGISTER ? "username or email already taken" : "unauthorized");
      else job_reply(j, j->kind == W_REGISTER ? 201 : 200, O->p, O->n);
      break;
    }
    case W_FOLLOW: case W_UNFOLLOW:
      while (pg_next(r, &row)) {
        has = true;
        render_profile(O, row.v[1], row.l[1], row.v[2], row.l[2], row.v[3], row.l[3], j->kind == W_FOLLOW);
      }
      if (!has) job_error(j, 404, "not found");
      else job_reply(j, 200, O->p, O->n);
      break;
    case W_FAV: case W_UNFAV:
      while (pg_next(r, &row)) { has = true; a0 = be64(row.v[0]); }
      if (!has) { job_error(j, 404, "not found"); break; }
      j->kind = K_ARTICLE_ID;
      j->id = a0;
      read_enqueue(j);
      break;
    case W_ARTICLE:
      while (pg_next(r, &row)) a0 = be64(row.v[0]);
      if (j->ntags) {
        while (pg_next(r, &row)) {}
        while (pg_next(r, &row)) {}
      }
      j->kind = K_ARTICLE_ID;
      j->id = a0;
      j->status_hint = 201;
      read_enqueue(j);
      break;
    case W_ARTICLE_PUT:
      while (pg_next(r, &row)) { has = true; a0 = be64(row.v[0]); a1 = be64(row.v[1]); }
      if (!has) { job_error(j, 404, "not found"); break; }
      if (a1 != j->viewer) { job_error(j, 403, "forbidden"); break; }
      j->kind = K_ARTICLE_ID;
      j->id = a0;
      read_enqueue(j);
      break;
    case W_ARTICLE_DEL: case W_COMMENT_DEL:
      while (pg_next(r, &row)) { has = true; a1 = be64(row.v[0]); }
      if (!has) { job_error(j, 404, "not found"); break; }
      if (a1 != j->viewer) { job_error(j, 403, "forbidden"); break; }
      job_reply(j, 204, "", 0);
      break;
    case W_COMMENT:
      while (pg_next(r, &row)) {
        has = true;
        buf_lit(O, "{\"comment\":{\"id\":");
        buf_i64(O, be64(row.v[0]));
        buf_lit(O, ",\"createdAt\":");
        buf_ts(O, be64(row.v[1]));
        buf_lit(O, ",\"updatedAt\":");
        buf_ts(O, be64(row.v[2]));
        buf_lit(O, ",\"body\":\"");
        buf_json(O, row.v[3], row.l[3]);
        buf_lit(O, "\",\"author\":{\"username\":\"");
        buf_json(O, row.v[4], row.l[4]);
        buf_lit(O, "\",\"bio\":");
        if (row.l[5] < 0) buf_lit(O, "null");
        else { buf_ch(O, '"'); buf_json(O, row.v[5], row.l[5]); buf_ch(O, '"'); }
        buf_lit(O, ",\"image\":");
        if (row.l[6] < 0) buf_lit(O, "null");
        else { buf_ch(O, '"'); buf_json(O, row.v[6], row.l[6]); buf_ch(O, '"'); }
        buf_lit(O, ",\"following\":false}}}");
      }
      if (!has) job_error(j, 404, "not found");
      else job_reply(j, 201, O->p, O->n);
      break;
  }
}

static void fail_alone(job *j, const pg_res *r) {
  if (!strcmp(r->sqlstate, "23505")) {
    job_error(j, 422, "already taken");
  } else if (!strcmp(r->sqlstate, "23503")) {
    if (strstr(r->constraint, "author_id") || strstr(r->constraint, "user_id") || strstr(r->constraint, "follower_id")) job_error(j, 401, "unauthorized");
    else job_error(j, 404, "not found");
  } else {
    fprintf(stderr, "write failed: %s\n", r->sqlstate);
    job_error(j, 500, "internal error");
  }
}

static pthread_mutex_t q_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_cv = PTHREAD_COND_INITIALIZER;
static job *q_head, *q_tail;

void write_enqueue(job *j) {
  j->next = NULL;
  pthread_mutex_lock(&q_mu);
  bool was_empty = !q_head;
  if (q_tail) q_tail->next = j;
  else q_head = j;
  q_tail = j;
  if (was_empty) pthread_cond_signal(&q_cv);
  pthread_mutex_unlock(&q_mu);
}

typedef struct {
  pg_t pg;
  arena_t a;
  buf_t out;
} wr_t;

static bool ensure(wr_t *w) {
  if (w->pg.fd >= 0) return true;
  for (int i = 0; i < 5; i++) {
    if (pg_connect(&w->pg, WSET, NWSET, WRITE_STMTS, NWST)) return true;
    struct timespec ts = {0, 200000000};
    nanosleep(&ts, NULL);
  }
  return false;
}

static void *write_main(void *arg) {
  wr_t *w = arg;
  const char *pol = getenv("DRAIN_SCHED");
  thread_sched(pol ? pol : "batch", 0);
  arena_init(&w->a, (size_t)1 << 31);
  job *g[GROUP];
  ensure(w);
  jmp_buf fail;
  for (;;) {
    pthread_mutex_lock(&q_mu);
    while (!q_head) pthread_cond_wait(&q_cv, &q_mu);
    int n = 0;
    while (q_head && n < GROUP) {
      g[n++] = q_head;
      q_head = q_head->next;
    }
    if (!q_head) q_tail = NULL;
    else pthread_cond_signal(&q_cv);
    pthread_mutex_unlock(&q_mu);
    if (!ensure(w)) {  // nothing was sent: safe to report failure
      for (int i = 0; i < n; i++) job_error(g[i], 500, "database unavailable");
      continue;
    }
    w->a.off = 0;
    w->a.fail = &fail;
    if (setjmp(fail)) {  // a result too large for the arena: the wire is mid-message
      pg_close(&w->pg);
      for (int i = 0; i < n; i++) job_error(g[i], 500, "internal error");
      continue;
    }
    for (int i = 0; i < n; i++) bind_one(&w->pg, g[i]);
    pg_res r;
    if (pg_exchange(&w->pg, &w->a, &r)) {
      for (int i = 0; i < n; i++) finish_one(g[i], &r, &w->out);
      continue;
    }
    if (r.lost) {
      pg_close(&w->pg);
      for (int i = 0; i < n; i++) job_error(g[i], 500, "database connection lost");
      continue;
    }
    if (n == 1) {
      fail_alone(g[0], &r);
      continue;
    }
    for (int i = 0; i < n; i++) {
      if (!ensure(w)) {
        job_error(g[i], 500, "database unavailable");
        continue;
      }
      w->a.off = 0;
      bind_one(&w->pg, g[i]);
      if (pg_exchange(&w->pg, &w->a, &r)) finish_one(g[i], &r, &w->out);
      else if (r.lost) {
        pg_close(&w->pg);
        job_error(g[i], 500, "database connection lost");
      } else fail_alone(g[i], &r);
    }
  }
  return NULL;
}

void writes_start(int n) {
  for (int i = 0; i < n; i++) {
    wr_t *w = calloc(1, sizeof *w);
    w->pg.fd = -1;
    pthread_t t;
    pthread_create(&t, NULL, write_main, w);
  }
}
