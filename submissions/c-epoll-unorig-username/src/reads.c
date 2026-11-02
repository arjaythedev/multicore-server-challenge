// The read engine. A drain thread takes every waiting read and answers them together: each statement is a flat index
// scan over the distinct keys the batch needs, sorted and deduplicated here, and all joining happens here. Nothing
// outlives the batch: its arena is reset before the next one.
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

#include "pg.h"

// ---- statements
#define S(name, sql) {name, sql}
static const pg_stmt READ_STMTS[] = {
    S("tags", "SELECT id::int8, name FROM tags ORDER BY name"),
    S("u_id", "SELECT id, username, email, bio, image FROM users WHERE id = ANY($1::int8[])"),
    S("u_email", "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ANY($1::text[])"),
    S("u_name", "SELECT id, username, bio, image FROM users WHERE username = ANY($1::text[])"),
    S("w_all",
      "SELECT w.i, ARRAY(SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT w.l OFFSET w.o),"
      " (SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s)"
      " FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY w(l, o, i)"),
    S("w_tag",
      "SELECT w.i, ARRAY(SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id ORDER BY at.article_id DESC LIMIT w.l OFFSET w.o),"
      " (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = t.id LIMIT 1000) s)"
      " FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY w(n, l, o, i) JOIN tags t ON t.name = w.n"),
    S("w_author",
      "SELECT w.i, ARRAY(SELECT a.id FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT w.l OFFSET w.o),"
      " (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = u.id LIMIT 1000) s)"
      " FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY w(n, l, o, i) JOIN users u ON u.username = w.n"),
    S("w_fav",
      "SELECT w.i, ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = u.id ORDER BY f.article_id DESC LIMIT w.l OFFSET w.o),"
      " (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = u.id LIMIT 1000) s)"
      " FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY w(n, l, o, i) JOIN users u ON u.username = w.n"),
    S("fo_of", "SELECT follower_id, followee_id FROM follows WHERE follower_id = ANY($1::int8[])"),
    S("w_feed", "SELECT w.f, ARRAY(SELECT a.id FROM articles a WHERE a.author_id = w.f ORDER BY a.id DESC LIMIT w.k) FROM unnest($1::int8[], $2::int8[]) w(f, k)"),
    S("w_cnt", "SELECT w.f, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = w.f LIMIT 1000) s) FROM unnest($1::int8[]) w(f)"),
    S("a_slug", "SELECT id, slug, title, description, created_at, updated_at, author_id, body FROM articles WHERE slug = ANY($1::text[])"),
    S("a_idf", "SELECT id, slug, title, description, created_at, updated_at, author_id, body FROM articles WHERE id = ANY($1::int8[])"),
    S("a_meta", "SELECT id, slug, title, description, created_at, updated_at, author_id FROM articles WHERE id = ANY($1::int8[])"),
    S("c_slug",
      "SELECT a.slug, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id FROM articles a LEFT JOIN LATERAL ("
      " SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id"
      " ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true WHERE a.slug = ANY($1::text[])"),
    S("a_tags", "SELECT article_id, tag_id::int8 FROM article_tags WHERE article_id = ANY($1::int8[])"),
    S("f_cnt", "SELECT article_id, count(*) FROM favorites WHERE article_id = ANY($1::int8[]) GROUP BY article_id"),
    // Two arrays on one index: the planner's guess for two ANY conditions can flip to the other index with a linear filter on
    // the first array, which is ruinous at batch sizes. OFFSET 0 pins the primary-key scan, and the join hashes the second array.
    S("f_flag", "SELECT s.user_id, s.article_id FROM (SELECT user_id, article_id FROM favorites WHERE user_id = ANY($1::int8[]) OFFSET 0) s"
                " JOIN unnest($2::int8[]) a(id) ON a.id = s.article_id"),
    S("fo_flag", "SELECT s.follower_id, s.followee_id FROM (SELECT follower_id, followee_id FROM follows WHERE follower_id = ANY($1::int8[]) OFFSET 0) s"
                 " JOIN unnest($2::int8[]) a(id) ON a.id = s.followee_id"),
};
static const char *const SETTINGS[] = {
    "SET plan_cache_mode = force_generic_plan", "SET jit = off", "SET max_parallel_workers_per_gather = 0", "SET TimeZone = 'UTC'",
    "SET enable_seqscan = off",                 "SET enable_bitmapscan = off",
};
#define NSETTINGS (int)(sizeof SETTINGS / sizeof *SETTINGS)
#define NSTMTS (int)(sizeof READ_STMTS / sizeof *READ_STMTS)

static int64_t hub_est = 600;  // estimated articles that make an author worth counting first

// ---- batch-local maps
typedef struct {
  int64_t *k;
  int32_t *v;
  uint32_t mask;
} map64;
static void m64_init(map64 *m, arena_t *a, size_t expect) {
  uint32_t cap = 16;
  while (cap < expect * 2) cap <<= 1;
  m->k = arena_alloc(a, cap * sizeof(int64_t));
  m->v = arena_alloc(a, cap * sizeof(int32_t));
  memset(m->k, 0, cap * sizeof(int64_t));
  m->mask = cap - 1;
}
// Returns the slot for id (ids are never 0); *fresh tells whether it was empty.
static inline uint32_t m64_slot(const map64 *m, int64_t id) {
  uint32_t i = (uint32_t)(((uint64_t)id * 0x9E3779B97F4A7C15ULL) >> 32) & m->mask;
  while (m->k[i] && m->k[i] != id) i = (i + 1) & m->mask;
  return i;
}
static inline int32_t m64_get(const map64 *m, int64_t id) {
  uint32_t i = m64_slot(m, id);
  return m->k[i] ? m->v[i] : -1;
}

typedef struct {
  const char *s;
  uint32_t l;
  int32_t v;
} sent;
typedef struct {
  sent *e;
  uint32_t mask;
} mapstr;
static void ms_init(mapstr *m, arena_t *a, size_t expect) {
  uint32_t cap = 16;
  while (cap < expect * 2) cap <<= 1;
  m->e = arena_alloc(a, cap * sizeof(sent));
  memset(m->e, 0, cap * sizeof(sent));
  m->mask = cap - 1;
}
static inline uint32_t str_hash(const char *s, uint32_t l) {
  uint32_t h = 2166136261u;
  for (uint32_t i = 0; i < l; i++) h = (h ^ (uint8_t)s[i]) * 16777619u;
  return h;
}
static inline sent *ms_slot(const mapstr *m, const char *s, uint32_t l) {
  uint32_t i = str_hash(s, l) & m->mask;
  while (m->e[i].s && !(m->e[i].l == l && !memcmp(m->e[i].s, s, l))) i = (i + 1) & m->mask;
  return &m->e[i];
}

// A set of (a, b) pairs.
typedef struct {
  int64_t (*k)[2];
  uint32_t mask;
} pairset;
static inline uint32_t pair_hash(const pairset *p, int64_t a, int64_t b) {
  return (uint32_t)((((uint64_t)a * 0x9E3779B97F4A7C15ULL) ^ ((uint64_t)b * 0xC2B2AE3D27D4EB4FULL)) >> 32) & p->mask;
}
static void ps_init(pairset *p, arena_t *x, size_t expect) {
  uint32_t cap = 16;
  while (cap < expect * 2) cap <<= 1;
  p->k = arena_alloc(x, cap * 16);
  memset(p->k, 0, cap * 16);
  p->mask = cap - 1;
}
static inline void ps_add(pairset *p, int64_t a, int64_t b) {
  uint32_t i = pair_hash(p, a, b);
  while (p->k[i][0] && !(p->k[i][0] == a && p->k[i][1] == b)) i = (i + 1) & p->mask;
  p->k[i][0] = a;
  p->k[i][1] = b;
}
static inline bool ps_has(const pairset *p, int64_t a, int64_t b) {
  if (!p->k || !a) return false;
  uint32_t i = pair_hash(p, a, b);
  while (p->k[i][0]) {
    if (p->k[i][0] == a && p->k[i][1] == b) return true;
    i = (i + 1) & p->mask;
  }
  return false;
}

// Distinct ids, collected then sorted for the server.
typedef struct {
  map64 m;
  int64_t *v;
  int n;
} idset;
static void is_init(idset *s, arena_t *a, int cap) {
  m64_init(&s->m, a, cap);
  s->v = arena_alloc(a, (cap + 1) * sizeof(int64_t));
  s->n = 0;
}
static inline int is_add(idset *s, int64_t id) {
  uint32_t i = m64_slot(&s->m, id);
  if (s->m.k[i]) return s->m.v[i];
  s->m.k[i] = id;
  s->m.v[i] = s->n;
  s->v[s->n] = id;
  return s->n++;
}
static int cmp_i64(const void *a, const void *b) {
  int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
  return x < y ? -1 : x > y;
}
static void is_sort(idset *s) { qsort(s->v, s->n, sizeof(int64_t), cmp_i64); }

// ---- rows of a batch
typedef struct tagln {
  int rank;
  struct tagln *next;
} tagln;
typedef struct {
  int64_t id, author, created, updated, fav;
  const char *slug, *title, *desc, *body;
  int32_t sl, tl, dl, bl;
  tagln *tags;
  int ntags;
  uint32_t frag, frag_len, bfrag, bfrag_len;  // rendered once, in the thread's frag buffer
  int author_ix;
} art_t;
typedef struct {
  int64_t id;
  const char *name, *bio, *image;
  int32_t nl, bl, il;
  uint32_t frag, frag_len;
} author_t;
typedef struct cmt {
  int64_t id, created, updated, author;
  const char *body;
  int32_t bl;
  uint32_t frag, frag_len;
  int author_ix;
  struct cmt *next;
} cmt_t;
typedef struct {
  const char *slug;
  uint32_t sl;
  int64_t aid;
  cmt_t *first, *last;
  bool found;
} thread_t;
typedef struct {
  const char *arr;  // int8[] of the window's ids
  int n;
  int64_t count;
} win_t;
typedef struct {
  int kind;   // window kind
  int win;    // index among that kind's windows; -1 if the name is unknown (empty list)
  int64_t o;  // window's offset
  int64_t *ids;
  int n;
  int64_t count;
  int a;       // article index
  int thread;  // comment thread index
  pg_row row;  // user / profile row
  bool has_row;
} jb_t;
typedef struct {
  const char **names;
  uint32_t *lens;
  int64_t *l, *o;
  win_t *w;
  int n;
  mapstr keys;
} winset;

typedef struct {
  pg_t pg;
  arena_t a;
  buf_t frags, out;
  jmp_buf fail;
  int id;
} drain_t;

static void ws_init(winset *s, arena_t *a, int cap) {
  s->names = arena_alloc(a, (cap + 1) * sizeof(char *));
  s->lens = arena_alloc(a, (cap + 1) * sizeof(uint32_t));
  s->l = arena_alloc(a, (cap + 1) * sizeof(int64_t));
  s->o = arena_alloc(a, (cap + 1) * sizeof(int64_t));
  s->w = arena_alloc(a, (cap + 1) * sizeof(win_t));
  memset(s->w, 0, (cap + 1) * sizeof(win_t));
  s->n = 0;
  ms_init(&s->keys, a, cap);
}
#define SHALLOW_END 200  // pages ending here share one window per key
static int ws_add(winset *s, const char *name, uint32_t nl, int64_t lim, int64_t off, int64_t *o_out) {
  int64_t end = lim + off;
  if (end <= SHALLOW_END) {
    sent *e = ms_slot(&s->keys, name ? name : "", nl);
    if (e->s) {
      if (s->l[e->v] < end) s->l[e->v] = end;
      *o_out = 0;
      return e->v;
    }
    e->s = name ? name : "";
    e->l = nl;
    e->v = s->n;
    s->names[s->n] = name;
    s->lens[s->n] = nl;
    s->l[s->n] = end;
    s->o[s->n] = 0;
    *o_out = 0;
    return s->n++;
  }
  s->names[s->n] = name;
  s->lens[s->n] = nl;
  s->l[s->n] = lim;
  s->o[s->n] = off;
  *o_out = off;
  return s->n++;
}
static void ws_read(winset *s, pg_res *r) {
  pg_row row;
  while (pg_next(r, &row)) {
    int i = (int)be64(row.v[0]) - 1;
    if (i < 0 || i >= s->n) continue;
    s->w[i].n = pg_arr_i64(row.v[1], row.l[1], &s->w[i].arr);
    s->w[i].count = be64(row.v[2]);
  }
}

static int count_rows(const pg_res *r) {
  const char *p = r->p;
  int n = 0;
  while (p < r->end) {
    char t = p[0];
    if (t == 'C') break;
    if (t == 'D') n++;
    p += 1 + (uint32_t)be32s(p + 1);
  }
  return n;
}

// ---- rendering
static void text_or_null(buf_t *b, const char *s, int32_t l) {
  if (l < 0) {
    buf_lit(b, "null");
    return;
  }
  buf_ch(b, '"');
  buf_json(b, s, l);
  buf_ch(b, '"');
}
void render_user(buf_t *b, const char *user, size_t ul, const char *email, size_t el, const char *bio, int32_t bl, const char *image, int32_t il,
                 const char *token, size_t tl) {
  buf_lit(b, "{\"user\":{\"email\":\"");
  buf_json(b, email, el);
  buf_lit(b, "\",\"username\":\"");
  buf_json(b, user, ul);
  buf_lit(b, "\",\"bio\":");
  text_or_null(b, bio, bl);
  buf_lit(b, ",\"image\":");
  text_or_null(b, image, il);
  buf_lit(b, ",\"token\":\"");
  if (token) {
    buf_put(b, token, tl);
    buf_lit(b, "\"}}");
  }
}
void render_profile(buf_t *b, const char *user, size_t ul, const char *bio, int32_t bl, const char *image, int32_t il, bool following) {
  buf_lit(b, "{\"profile\":{\"username\":\"");
  buf_json(b, user, ul);
  buf_lit(b, "\",\"bio\":");
  text_or_null(b, bio, bl);
  buf_lit(b, ",\"image\":");
  text_or_null(b, image, il);
  buf_lit(b, ",\"following\":");
  if (following) buf_lit(b, "true}}");
  else buf_lit(b, "false}}");
}
static void author_frag(buf_t *f, author_t *u) {
  u->frag = f->n;
  buf_lit(f, "\"author\":{\"username\":\"");
  buf_json(f, u->name, u->nl);
  buf_lit(f, "\",\"bio\":");
  text_or_null(f, u->bio, u->bl);
  buf_lit(f, ",\"image\":");
  text_or_null(f, u->image, u->il);
  buf_lit(f, ",\"following\":");
  u->frag_len = f->n - u->frag;
}

typedef struct {
  const char *n;
  uint32_t l;
} tagname;

static void art_frag(buf_t *f, art_t *a, const tagname *tn) {
  a->frag = f->n;
  buf_lit(f, "\"slug\":\"");
  buf_json(f, a->slug, a->sl);
  buf_lit(f, "\",\"title\":\"");
  buf_json(f, a->title, a->tl);
  buf_lit(f, "\",\"description\":\"");
  buf_json(f, a->desc, a->dl);
  buf_lit(f, "\",\"tagList\":[");
  // Tags in rank (SQL name) order; lists are short.
  int cnt = 0, m = 0, stack[64];
  for (tagln *t = a->tags; t; t = t->next) cnt++;
  int *ranks = cnt <= 64 ? stack : malloc(sizeof(int) * cnt);
  for (tagln *t = a->tags; t; t = t->next) {
    int r = t->rank, i = m++;
    while (i > 0 && ranks[i - 1] > r) {
      ranks[i] = ranks[i - 1];
      i--;
    }
    ranks[i] = r;
  }
  for (int i = 0; i < m; i++) {
    if (i) buf_ch(f, ',');
    buf_ch(f, '"');
    buf_json(f, tn[ranks[i]].n, tn[ranks[i]].l);
    buf_ch(f, '"');
  }
  if (ranks != stack) free(ranks);
  buf_lit(f, "],\"createdAt\":");
  buf_ts(f, a->created);
  buf_lit(f, ",\"updatedAt\":");
  buf_ts(f, a->updated);
  buf_lit(f, ",\"favoritesCount\":");
  buf_i64(f, a->fav);
  buf_lit(f, ",\"favorited\":");
  a->frag_len = f->n - a->frag;
}

static inline void flag(buf_t *b, bool v) {
  if (v) buf_lit(b, "true");
  else buf_lit(b, "false");
}

// Responses identical within this batch: same statement results, no viewer flag set, same head.
typedef struct {
  uint64_t a, b;
  resp_t *r;
} rc_ent;
typedef struct {
  rc_ent *e;
  uint32_t mask;
  int n;
} rcache;
static void rc_init(rcache *c, arena_t *x, int expect) {
  uint32_t cap = 16;
  while (cap < (uint32_t)expect * 2) cap <<= 1;
  c->e = arena_alloc(x, cap * sizeof(rc_ent));
  memset(c->e, 0, cap * sizeof(rc_ent));
  c->mask = cap - 1;
  c->n = 0;
}
// a != 0. Answers j with a shared response, building it on the first use.
static bool rc_reuse(rcache *c, job *j, uint64_t a, uint64_t b, uint32_t *slot) {
  a = (a << 1) | j->gzip;
  uint32_t i = (uint32_t)(((a * 0x9E3779B97F4A7C15ULL) ^ (b * 0xC2B2AE3D27D4EB4FULL)) >> 32) & c->mask;
  while (c->e[i].a && !(c->e[i].a == a && c->e[i].b == b)) i = (i + 1) & c->mask;
  *slot = i;
  if (!c->e[i].a) {
    c->e[i].a = a;
    c->e[i].b = b;
    return false;
  }
  atomic_fetch_add_explicit(&c->e[i].r->refs, 1, memory_order_relaxed);
  j->r = c->e[i].r;
  loop_post(j);
  return true;
}
static void rc_keep(rcache *c, job *j, uint32_t slot, const char *body, size_t n, int status) {
  resp_t *r = resp_build(status, body, n, j->close, j->gzip);
  atomic_fetch_add_explicit(&r->refs, 1, memory_order_relaxed);
  c->e[slot].r = r;
  j->r = r;
  c->n++;
  loop_post(j);
}
static void rc_release(rcache *c) {
  for (uint32_t i = 0; i <= c->mask; i++)
    if (c->e[i].a) resp_unref(c->e[i].r);
}

// ---- one batch. Returns 0 when every job is answered, else 1 = connection lost, 2 = statement failed.
enum { B_OK, B_LOST, B_SQL };

#define EXCH(res)                                  \
  do {                                             \
    if (!pg_exchange(&d->pg, a, &(res))) return (res).lost ? B_LOST : B_SQL; \
  } while (0)

static void reply_ok(drain_t *d, job *j, buf_t *out) {
  job_reply(j, j->status_hint ? j->status_hint : 200, out->p, out->n);
  (void)d;
}

static int run_batch(drain_t *d, job **jobs, int n) {
  arena_t *a = &d->a;
  a->off = 0;
  buf_t *F = &d->frags, *O = &d->out;
  F->n = 0;
  jb_t *jb = arena_alloc(a, sizeof(jb_t) * n);
  idset uids, fviewers;
  is_init(&uids, a, n);
  is_init(&fviewers, a, n);
  mapstr emails, names, slugs_full, slugs_c;
  ms_init(&emails, a, n);
  ms_init(&names, a, n);
  ms_init(&slugs_full, a, n);
  ms_init(&slugs_c, a, n);
  const char **pe = arena_alloc(a, sizeof(char *) * (n + 1)), **pn = arena_alloc(a, sizeof(char *) * (n + 1));
  const char **ps = arena_alloc(a, sizeof(char *) * (n + 1)), **pc = arena_alloc(a, sizeof(char *) * (n + 1));
  uint32_t *le = arena_alloc(a, 4 * (n + 1)), *ln = arena_alloc(a, 4 * (n + 1)), *ls = arena_alloc(a, 4 * (n + 1)), *lc = arena_alloc(a, 4 * (n + 1));
  int ne = 0, nn = 0, ns = 0, nc = 0;
  idset aidsf;
  is_init(&aidsf, a, n);
  winset wa, wt, wu, wf;
  ws_init(&wa, a, n);
  ws_init(&wt, a, n);
  ws_init(&wu, a, n);
  ws_init(&wf, a, n);
  bool want_tags = false, tags_jobs = false, any_articles = false;

#define ADDSTR(m, arrp, arrl, cnt, S, L)        \
  do {                                          \
    sent *e_ = ms_slot(&(m), (S), (L));         \
    if (!e_->s) {                               \
      e_->s = (S);                              \
      e_->l = (L);                              \
      e_->v = (cnt);                            \
      (arrp)[(cnt)] = (S);                      \
      (arrl)[(cnt)] = (L);                      \
      (cnt)++;                                  \
    }                                           \
  } while (0)

  for (int i = 0; i < n; i++) {
    job *j = jobs[i];
    jb_t *x = &jb[i];
    memset(x, 0, offsetof(jb_t, row));
    x->has_row = false;
    x->win = -1;
    x->a = -1;
    x->thread = -1;
    if (!j) continue;
    j->b = x;
    switch (j->kind) {
      case K_TAGS: tags_jobs = want_tags = true; break;
      case K_USER: is_add(&uids, j->viewer); break;
      case K_LOGIN: ADDSTR(emails, pe, le, ne, j->s1, j->l1); break;
      case K_PROFILE: ADDSTR(names, pn, ln, nn, j->s1, j->l1); break;
      case K_LIST_ALL: x->win = ws_add(&wa, NULL, 0, j->lim, j->off, &x->o); any_articles = true; break;
      case K_LIST_TAG: x->win = ws_add(&wt, j->s1, j->l1, j->lim, j->off, &x->o); any_articles = true; break;
      case K_LIST_AUTHOR: x->win = ws_add(&wu, j->s1, j->l1, j->lim, j->off, &x->o); any_articles = true; break;
      case K_LIST_FAV: x->win = ws_add(&wf, j->s1, j->l1, j->lim, j->off, &x->o); any_articles = true; break;
      case K_FEED: is_add(&fviewers, j->viewer); any_articles = true; break;
      case K_ARTICLE_SLUG: ADDSTR(slugs_full, ps, ls, ns, j->s1, j->l1); any_articles = true; break;
      case K_ARTICLE_ID: is_add(&aidsf, j->id); any_articles = true; break;
      case K_COMMENTS: ADDSTR(slugs_c, pc, lc, nc, j->s1, j->l1); break;
    }
  }
  if (any_articles) want_tags = true;

  // ---- phase 1
  pg_t *c = &d->pg;
  if (want_tags) { pg_bind(c, "tags", 0); pg_bind_end(c); }
  if (uids.n) { is_sort(&uids); pg_bind(c, "u_id", 1); pg_i64arr(c, uids.v, uids.n); pg_bind_end(c); }
  if (ne) { pg_bind(c, "u_email", 1); pg_textarr(c, pe, le, ne); pg_bind_end(c); }
  if (nn) { pg_bind(c, "u_name", 1); pg_textarr(c, pn, ln, nn); pg_bind_end(c); }
  if (wa.n) { pg_bind(c, "w_all", 2); pg_i64arr(c, wa.l, wa.n); pg_i64arr(c, wa.o, wa.n); pg_bind_end(c); }
#define BINDW(s, name)                                                                                \
  if ((s).n) {                                                                                        \
    pg_bind(c, name, 3); pg_textarr(c, (s).names, (s).lens, (s).n); pg_i64arr(c, (s).l, (s).n); pg_i64arr(c, (s).o, (s).n); pg_bind_end(c); \
  }
  BINDW(wt, "w_tag") BINDW(wu, "w_author") BINDW(wf, "w_fav")
  if (fviewers.n) { is_sort(&fviewers); pg_bind(c, "fo_of", 1); pg_i64arr(c, fviewers.v, fviewers.n); pg_bind_end(c); }
  if (ns) { pg_bind(c, "a_slug", 1); pg_textarr(c, ps, ls, ns); pg_bind_end(c); }
  if (aidsf.n) { is_sort(&aidsf); pg_bind(c, "a_idf", 1); pg_i64arr(c, aidsf.v, aidsf.n); pg_bind_end(c); }
  if (nc) { pg_bind(c, "c_slug", 1); pg_textarr(c, pc, lc, nc); pg_bind_end(c); }
  pg_res r;
  EXCH(r);

  pg_row row;
  // tags
  tagname *tn = NULL;
  map64 tagmap = {0};
  int ntagn = 0;
#define READ_TAGS()                                                                     \
  do {                                                                                  \
    int nr_ = count_rows(&r);                                                           \
    tn = arena_alloc(a, sizeof(tagname) * (nr_ + 1));                                   \
    m64_init(&tagmap, a, nr_ + 1);                                                      \
    ntagn = 0;                                                                          \
    while (pg_next(&r, &row)) {                                                         \
      uint32_t s_ = m64_slot(&tagmap, be64(row.v[0]));                                  \
      tagmap.k[s_] = be64(row.v[0]);                                                    \
      tagmap.v[s_] = ntagn;                                                             \
      tn[ntagn].n = row.v[1];                                                           \
      tn[ntagn].l = row.l[1];                                                           \
      ntagn++;                                                                          \
    }                                                                                   \
  } while (0)
  if (want_tags) READ_TAGS();
  if (tags_jobs) {
    O->n = 0;
    buf_lit(O, "{\"tags\":[");
    for (int i = 0; i < ntagn; i++) {
      if (i) buf_ch(O, ',');
      buf_ch(O, '"');
      buf_json(O, tn[i].n, tn[i].l);
      buf_ch(O, '"');
    }
    buf_lit(O, "]}");
    rcache tc;
    rc_init(&tc, a, 2);
    for (int i = 0; i < n; i++)
      if (jobs[i] && jobs[i]->kind == K_TAGS) {
        uint32_t sl;
        job *j = jobs[i];
        jobs[i] = NULL;
        if (j->close) reply_ok(d, j, O);
        else if (!rc_reuse(&tc, j, 1, 0, &sl)) rc_keep(&tc, j, sl, O->p, O->n, 200);
      }
    rc_release(&tc);
  }
  // users by id
  if (uids.n) {
    pg_row *rows = arena_alloc(a, sizeof(pg_row) * uids.n);
    map64 um;
    m64_init(&um, a, uids.n);
    int nu = 0;
    while (pg_next(&r, &row)) {
      if (nu >= uids.n) continue;
      rows[nu] = row;
      uint32_t s = m64_slot(&um, be64(row.v[0]));
      um.k[s] = be64(row.v[0]);
      um.v[s] = nu++;
    }
    for (int i = 0; i < n; i++) {
      job *j = jobs[i];
      if (!j || j->kind != K_USER) continue;
      int ix = m64_get(&um, j->viewer);
      if (ix < 0) job_error(j, 401, "unauthorized");
      else {
        pg_row *u = &rows[ix];
        O->n = 0;
        render_user(O, u->v[1], u->l[1], u->v[2], u->l[2], u->v[3], u->l[3], u->v[4], u->l[4], j->token, j->token_len);
        reply_ok(d, j, O);
      }
      jobs[i] = NULL;
    }
  }
  // logins go on to the hashers with the rendered head of their response
  if (ne) {
    while (pg_next(&r, &row)) {
      sent *e = ms_slot(&emails, row.v[2], row.l[2]);
      if (!e->s) continue;
      for (int i = 0; i < n; i++) {
        job *j = jobs[i];
        if (!j || j->kind != K_LOGIN || j->l1 != (uint32_t)row.l[2] || memcmp(j->s1, row.v[2], j->l1)) continue;
        O->n = 0;
        render_user(O, row.v[1], row.l[1], row.v[2], row.l[2], row.v[3], row.l[3], row.v[4], row.l[4], NULL, 0);
        j->resp = malloc(O->n);
        memcpy(j->resp, O->p, O->n);
        j->resp_len = O->n;
        j->id = be64(row.v[0]);
        hash_enqueue_verify(j, row.v[5], row.l[5]);
        jobs[i] = NULL;
      }
    }
    for (int i = 0; i < n; i++)
      if (jobs[i] && jobs[i]->kind == K_LOGIN) {
        job_error(jobs[i], 401, "unauthorized");
        jobs[i] = NULL;
      }
  }
  // profiles
  pg_row *prow = NULL;
  int np = 0;
  mapstr pm;
  if (nn) {
    prow = arena_alloc(a, sizeof(pg_row) * nn);
    ms_init(&pm, a, nn);
    while (pg_next(&r, &row)) {
      if (np >= nn) continue;
      prow[np] = row;
      sent *e = ms_slot(&pm, row.v[1], row.l[1]);
      e->s = row.v[1];
      e->l = row.l[1];
      e->v = np++;
    }
  }
  if (wa.n) ws_read(&wa, &r);
  if (wt.n) ws_read(&wt, &r);
  if (wu.n) ws_read(&wu, &r);
  if (wf.n) ws_read(&wf, &r);

  // viewers' followees
  int64_t **fol = NULL;
  int *folen = NULL;
  if (fviewers.n) {
    int total = count_rows(&r);
    map64 vm;
    m64_init(&vm, a, fviewers.n);
    for (int i = 0; i < fviewers.n; i++) {
      uint32_t s = m64_slot(&vm, fviewers.v[i]);
      vm.k[s] = fviewers.v[i];
      vm.v[s] = i;
    }
    fviewers.m = vm;
    fol = arena_alloc(a, sizeof(int64_t *) * fviewers.n);
    folen = arena_alloc(a, sizeof(int) * fviewers.n);
    memset(folen, 0, sizeof(int) * fviewers.n);
    int64_t *all = arena_alloc(a, sizeof(int64_t) * (total + 1));
    int at = 0, cur = -1;
    while (pg_next(&r, &row)) {
      int v = m64_get(&vm, be64(row.v[0]));
      if (v != cur) {  // rows arrive per follower in index order
        cur = v;
        fol[v] = all + at;
      }
      all[at++] = be64(row.v[1]);
      folen[v]++;
    }
  }

  // articles with body
  int cap_arts = 1024;
  for (int i = 0; i < n; i++)
    if (jobs[i] && jobs[i]->kind <= K_FEED && jobs[i]->kind >= K_LIST_ALL) cap_arts += jobs[i]->lim;
  cap_arts += ns + aidsf.n + 16;
  // Feed and window slices are bounded by the jobs' limits.
  art_t *arts = arena_alloc(a, sizeof(art_t) * cap_arts);
  int narts = 0;
  map64 artm;
  m64_init(&artm, a, cap_arts);
  mapstr slugm;
  ms_init(&slugm, a, ns + aidsf.n + nc + 1);
  idset authors;
  int n_author_cap = cap_arts + nn + 1024;
#define READ_FULL_ART()                                                       \
  do {                                                                        \
    int64_t id_ = be64(row.v[0]);                                             \
    uint32_t s_ = m64_slot(&artm, id_);                                       \
    int ix_;                                                                  \
    if (artm.k[s_]) ix_ = artm.v[s_];                                         \
    else {                                                                    \
      if (narts >= cap_arts) continue;                                        \
      ix_ = narts++;                                                          \
      artm.k[s_] = id_;                                                       \
      artm.v[s_] = ix_;                                                       \
    }                                                                         \
    art_t *x_ = &arts[ix_];                                                   \
    memset(x_, 0, sizeof *x_);                                                \
    x_->id = id_;                                                             \
    x_->slug = row.v[1]; x_->sl = row.l[1];                                   \
    x_->title = row.v[2]; x_->tl = row.l[2];                                  \
    x_->desc = row.v[3]; x_->dl = row.l[3];                                   \
    x_->created = be64(row.v[4]);                                             \
    x_->updated = be64(row.v[5]);                                             \
    x_->author = be64(row.v[6]);                                              \
    x_->author_ix = -1;                                                       \
    if (row.n > 7) { x_->body = row.v[7]; x_->bl = row.l[7]; }                \
    if (row.n > 7) {                                                          \
      sent *e_ = ms_slot(&slugm, x_->slug, x_->sl);                           \
      if (!e_->s) { e_->s = x_->slug; e_->l = x_->sl; e_->v = ix_; }          \
    }                                                                         \
  } while (0)
  if (ns) while (pg_next(&r, &row)) READ_FULL_ART();
  if (aidsf.n) while (pg_next(&r, &row)) READ_FULL_ART();

  // comment threads
  thread_t *th = NULL;
  int ncm = 0;
  mapstr thm;
  if (nc) {
    th = arena_alloc(a, sizeof(thread_t) * nc);
    int rows_n = count_rows(&r);
    n_author_cap += rows_n;
    cmt_t *cs = arena_alloc(a, sizeof(cmt_t) * (rows_n + 1));
    int nt = 0;
    ms_init(&thm, a, nc);
    thread_t *cur = NULL;
    while (pg_next(&r, &row)) {
      if (!cur || cur->sl != (uint32_t)row.l[0] || memcmp(cur->slug, row.v[0], cur->sl)) {
        sent *e = ms_slot(&thm, row.v[0], row.l[0]);
        if (!e->s) {
          if (nt >= nc) continue;
          e->s = row.v[0];
          e->l = row.l[0];
          e->v = nt;
          cur = &th[nt++];
          cur->slug = row.v[0];
          cur->sl = row.l[0];
          cur->aid = be64(row.v[1]);
          cur->first = cur->last = NULL;
          cur->found = true;
        } else {
          cur = &th[e->v];
        }
      }
      if (row.l[2] < 0) continue;  // a thread with no comments
      cmt_t *m = &cs[ncm++];
      m->id = be64(row.v[2]);
      m->body = row.v[3];
      m->bl = row.l[3];
      m->created = be64(row.v[4]);
      m->updated = be64(row.v[5]);
      m->author = be64(row.v[6]);
      m->next = NULL;
      m->frag_len = 0;
      if (cur->last) cur->last->next = m;
      else cur->first = m;
      cur->last = m;
    }
    for (int i = 0; i < n; i++) {
      job *j = jobs[i];
      if (!j || j->kind != K_COMMENTS) continue;
      sent *e = ms_slot(&thm, j->s1, j->l1);
      if (!e->s) {
        job_error(j, 404, "not found");
        jobs[i] = NULL;
      } else {
        jb[i].thread = e->v;
      }
    }
  }
  thread_t *threads = th;

  // ---- phase 2: feeds, from each distinct followee's newest ids
  if (fviewers.n) {
    idset fe;
    int fcap = 16;
    int total = 0;
    for (int i = 0; i < fviewers.n; i++) total += folen[i];
    fcap += total;
    is_init(&fe, a, fcap);
    int64_t *fk = arena_alloc(a, sizeof(int64_t) * fcap);
    memset(fk, 0, sizeof(int64_t) * fcap);
    for (int i = 0; i < n; i++) {
      job *j = jobs[i];
      if (!j || j->kind != K_FEED) continue;
      int v = m64_get(&fviewers.m, j->viewer);
      for (int q = 0; q < folen[v]; q++) {
        int ix = is_add(&fe, fol[v][q]);
        int64_t k = j->lim + j->off;
        if (fk[ix] < k) fk[ix] = k;
      }
    }
    win_t *fw = arena_alloc(a, sizeof(win_t) * (fe.n + 1));
    memset(fw, 0, sizeof(win_t) * (fe.n + 1));
    if (fe.n) {
      pg_bind(c, "w_feed", 2);
      pg_i64arr(c, fe.v, fe.n);
      pg_i64arr(c, fk, fe.n);
      pg_bind_end(c);
      EXCH(r);
      int64_t maxid = 1;
      while (pg_next(&r, &row)) {
        int ix = m64_get(&fe.m, be64(row.v[0]));
        if (ix < 0) continue;
        fw[ix].n = pg_arr_i64(row.v[1], row.l[1], &fw[ix].arr);
        // An array shorter than asked for holds all of the author's articles, so it is the exact count.
        fw[ix].count = fw[ix].n < fk[ix] ? fw[ix].n : -1;
        if (fw[ix].n && PG_ARR_AT(fw[ix].arr, 0) > maxid) maxid = PG_ARR_AT(fw[ix].arr, 0);
      }
      // Counts stop at 1,000 per viewer. Most viewers follow an author with 1,000+ articles, and that alone settles their
      // count, so authors who look that big (from how densely their newest ids fall) are counted first. Everyone else's
      // counts are read only for viewers still unsettled. The result is the exact capped count either way.
      for (int round = 0; round < 2; round++) {
        idset want;
        is_init(&want, a, fe.n + 1);
        for (int i = 0; i < n; i++) {
          job *j = jobs[i];
          if (!j || j->kind != K_FEED) continue;
          int v = m64_get(&fviewers.m, j->viewer);
          int64_t known = 0;
          for (int q = 0; q < folen[v]; q++) {
            win_t *w = &fw[m64_get(&fe.m, fol[v][q])];
            if (w->count > 0) known += w->count;
          }
          if (known >= 1000) continue;
          for (int q = 0; q < folen[v]; q++) {
            int ix = m64_get(&fe.m, fol[v][q]);
            win_t *w = &fw[ix];
            if (w->count >= 0) continue;
            // Estimated articles: the density of its newest k ids over the whole id range.
            int64_t span = PG_ARR_AT(w->arr, 0) - PG_ARR_AT(w->arr, w->n - 1) + 1;
            bool big = (int64_t)w->n * maxid / span >= hub_est;
            if (round == 1 || big) is_add(&want, fol[v][q]);
          }
        }
        if (!want.n) continue;
        is_sort(&want);
        pg_bind(c, "w_cnt", 1);
        pg_i64arr(c, want.v, want.n);
        pg_bind_end(c);
        EXCH(r);
        while (pg_next(&r, &row)) {
          int ix = m64_get(&fe.m, be64(row.v[0]));
          if (ix >= 0) fw[ix].count = be64(row.v[1]);
        }
      }
    }
    // Merge: repeatedly take the largest head among the viewer's followees.
    int *pos = NULL;
    int poscap = 0;
    for (int i = 0; i < n; i++) {
      job *j = jobs[i];
      if (!j || j->kind != K_FEED) continue;
      jb_t *x = &jb[i];
      int v = m64_get(&fviewers.m, j->viewer);
      int m = folen[v];
      if (m > poscap) {
        poscap = m * 2;
        pos = arena_alloc(a, sizeof(int) * poscap);
      }
      int64_t cnt = 0;
      for (int q = 0; q < m; q++) {
        pos[q] = 0;
        int64_t kc = fw[m64_get(&fe.m, fol[v][q])].count;
        if (kc > 0) cnt += kc;
      }
      x->count = cnt > 1000 ? 1000 : cnt;
      x->ids = arena_alloc(a, sizeof(int64_t) * j->lim);
      x->n = 0;
      int64_t skip = j->off;
      win_t **ws = arena_alloc(a, sizeof(win_t *) * (m + 1));
      for (int q = 0; q < m; q++) ws[q] = &fw[m64_get(&fe.m, fol[v][q])];
      while (x->n < j->lim) {
        int best = -1;
        int64_t bv = -1;
        for (int q = 0; q < m; q++) {
          if (pos[q] >= ws[q]->n) continue;
          int64_t h = PG_ARR_AT(ws[q]->arr, pos[q]);
          if (h > bv) {
            bv = h;
            best = q;
          }
        }
        if (best < 0) break;
        pos[best]++;
        if (skip > 0) skip--;
        else x->ids[x->n++] = bv;
      }
    }
  }

  // slices of the shared windows
  for (int i = 0; i < n; i++) {
    job *j = jobs[i];
    if (!j || j->kind < K_LIST_ALL || j->kind > K_LIST_FAV) continue;
    jb_t *x = &jb[i];
    winset *ws = j->kind == K_LIST_ALL ? &wa : j->kind == K_LIST_TAG ? &wt : j->kind == K_LIST_AUTHOR ? &wu : &wf;
    win_t *w = &ws->w[x->win];
    x->count = w->count;
    x->ids = arena_alloc(a, sizeof(int64_t) * (j->lim + 1));
    x->n = 0;
    for (int64_t q = j->off - x->o; q < w->n && x->n < j->lim; q++) x->ids[x->n++] = PG_ARR_AT(w->arr, q);
  }

  // ---- phase 3: article rows of every page
  idset need;
  int need_cap = 16;
  for (int i = 0; i < n; i++)
    if (jobs[i] && jobs[i]->kind >= K_LIST_ALL && jobs[i]->kind <= K_FEED) need_cap += jb[i].n;
  is_init(&need, a, need_cap);
  for (int i = 0; i < n; i++) {
    job *j = jobs[i];
    if (!j || j->kind < K_LIST_ALL || j->kind > K_FEED) continue;
    for (int q = 0; q < jb[i].n; q++)
      if (m64_get(&artm, jb[i].ids[q]) < 0) is_add(&need, jb[i].ids[q]);
  }
  if (need.n) {
    is_sort(&need);
    pg_bind(c, "a_meta", 1);
    pg_i64arr(c, need.v, need.n);
    pg_bind_end(c);
    EXCH(r);
    while (pg_next(&r, &row)) READ_FULL_ART();
  }

  // ---- phase 4: everything keyed by those articles
  is_init(&authors, a, n_author_cap);
  idset aidall, favv, folv;
  is_init(&aidall, a, narts + 1);
  is_init(&favv, a, n);
  is_init(&folv, a, n);
  for (int i = 0; i < narts; i++) {
    is_add(&aidall, arts[i].id);
    arts[i].author_ix = -1;
    is_add(&authors, arts[i].author);
  }
  int nthreads = 0;
  if (nc) {
    for (uint32_t i = 0; i <= thm.mask; i++)
      if (thm.e[i].s && thm.e[i].v + 1 > nthreads) nthreads = thm.e[i].v + 1;
    for (int i = 0; i < nthreads; i++)
      for (cmt_t *m = threads[i].first; m; m = m->next) is_add(&authors, m->author);
  }
  idset folt;
  is_init(&folt, a, authors.n + np + 1);
  for (int i = 0; i < authors.n; i++) is_add(&folt, authors.v[i]);
  for (int i = 0; i < np; i++) is_add(&folt, be64(prow[i].v[0]));
  for (int i = 0; i < n; i++) {
    job *j = jobs[i];
    if (!j || !j->viewer) continue;
    switch (j->kind) {
      case K_FEED: is_add(&favv, j->viewer); break;
      case K_LIST_ALL: case K_LIST_TAG: case K_LIST_AUTHOR: case K_LIST_FAV: case K_ARTICLE_SLUG: case K_ARTICLE_ID:
        is_add(&favv, j->viewer);
        is_add(&folv, j->viewer);
        break;
      case K_COMMENTS: case K_PROFILE: is_add(&folv, j->viewer); break;
    }
  }
  if (aidall.n) {
    is_sort(&aidall);
    pg_bind(c, "a_tags", 1); pg_i64arr(c, aidall.v, aidall.n); pg_bind_end(c);
    pg_bind(c, "f_cnt", 1); pg_i64arr(c, aidall.v, aidall.n); pg_bind_end(c);
  }
  if (authors.n) { is_sort(&authors); pg_bind(c, "u_id", 1); pg_i64arr(c, authors.v, authors.n); pg_bind_end(c); }
  bool ff = aidall.n && favv.n, fo = folv.n && folt.n;
  if (ff) { is_sort(&favv); pg_bind(c, "f_flag", 2); pg_i64arr(c, favv.v, favv.n); pg_i64arr(c, aidall.v, aidall.n); pg_bind_end(c); }
  if (fo) { is_sort(&folv); is_sort(&folt); pg_bind(c, "fo_flag", 2); pg_i64arr(c, folv.v, folv.n); pg_i64arr(c, folt.v, folt.n); pg_bind_end(c); }
  author_t *au = NULL;
  int nau = 0;
  map64 aum;
  pairset fav_ps = {0}, fol_ps = {0};
  bool tag_miss = false;
  if (aidall.n || authors.n || ff || fo) {
    EXCH(r);
    if (aidall.n) {
      int nt = count_rows(&r);
      tagln *tl = arena_alloc(a, sizeof(tagln) * (nt + 1));
      int ti = 0;
      while (pg_next(&r, &row)) {
        int ix = m64_get(&artm, be64(row.v[0]));
        int rank = m64_get(&tagmap, be64(row.v[1]));
        if (ix < 0) continue;
        if (rank < 0) {
          tag_miss = true;
          rank = (int)be64(row.v[1]) | 0x40000000;  // resolved below
        }
        tl[ti].rank = rank;
        tl[ti].next = arts[ix].tags;
        arts[ix].tags = &tl[ti++];
      }
      while (pg_next(&r, &row)) {
        int ix = m64_get(&artm, be64(row.v[0]));
        if (ix >= 0) arts[ix].fav = be64(row.v[1]);
      }
    }
    if (authors.n) {
      au = arena_alloc(a, sizeof(author_t) * authors.n);
      m64_init(&aum, a, authors.n);
      while (pg_next(&r, &row)) {
        if (nau >= authors.n) continue;
        author_t *u = &au[nau];
        u->id = be64(row.v[0]);
        u->name = row.v[1];
        u->nl = row.l[1];
        u->bio = row.v[3];
        u->bl = row.l[3];
        u->image = row.v[4];
        u->il = row.l[4];
        uint32_t s = m64_slot(&aum, u->id);
        aum.k[s] = u->id;
        aum.v[s] = nau++;
        author_frag(F, u);
      }
    }
    if (ff) {
      ps_init(&fav_ps, a, count_rows(&r) + 1);
      while (pg_next(&r, &row)) ps_add(&fav_ps, be64(row.v[0]), be64(row.v[1]));
    }
    if (fo) {
      ps_init(&fol_ps, a, count_rows(&r) + 1);
      while (pg_next(&r, &row)) ps_add(&fol_ps, be64(row.v[0]), be64(row.v[1]));
    }
  }
  if (tag_miss) {  // a tag created after the first phase's snapshot
    pg_bind(c, "tags", 0);
    pg_bind_end(c);
    EXCH(r);
    READ_TAGS();
    for (int i = 0; i < narts; i++)
      for (tagln *t = arts[i].tags; t; t = t->next)
        if (t->rank & 0x40000000) {
          int rk = m64_get(&tagmap, t->rank & 0x3fffffff);
          t->rank = rk < 0 ? 0 : rk;
        }
  }

  // ---- render
  for (int i = 0; i < narts; i++) {
    if (!arts[i].slug) continue;
    arts[i].author_ix = authors.n ? m64_get(&aum, arts[i].author) : -1;
    art_frag(F, &arts[i], tn);
  }
  rcache rc;
  rc_init(&rc, a, n);
  for (int i = 0; i < n; i++) {
    job *j = jobs[i];
    if (!j) continue;
    jb_t *x = &jb[i];
    O->n = 0;
    uint32_t sl = 0;
    switch (j->kind) {
      case K_PROFILE: {
        sent *e = nn ? ms_slot(&pm, j->s1, j->l1) : NULL;
        if (!e || !e->s) {
          job_error(j, 404, "not found");
          break;
        }
        pg_row *u = &prow[e->v];
        render_profile(O, u->v[1], u->l[1], u->v[2], u->l[2], u->v[3], u->l[3], ps_has(&fol_ps, j->viewer, be64(u->v[0])));
        reply_ok(d, j, O);
        break;
      }
      case K_LIST_ALL: case K_LIST_TAG: case K_LIST_AUTHOR: case K_LIST_FAV: case K_FEED: {
        bool any_flag = j->close || j->kind == K_FEED;
        for (int q = 0; q < x->n && !any_flag && j->viewer; q++) {
          int ix = m64_get(&artm, x->ids[q]);
          if (ix >= 0 && (ps_has(&fav_ps, j->viewer, arts[ix].id) || ps_has(&fol_ps, j->viewer, arts[ix].author))) any_flag = true;
        }
        // Same window, slice and limit: the same page.
        bool share = !any_flag && j->kind != K_FEED;
        if (share && rc_reuse(&rc, j, ((uint64_t)j->kind << 32) | (uint64_t)x->win, ((uint64_t)j->off << 8) | (uint64_t)j->lim, &sl)) break;
        buf_lit(O, "{\"articles\":[");
        bool first = true;
        for (int q = 0; q < x->n; q++) {
          int ix = m64_get(&artm, x->ids[q]);
          if (ix < 0 || !arts[ix].slug) continue;
          art_t *t = &arts[ix];
          if (!first) buf_ch(O, ',');
          first = false;
          buf_ch(O, '{');
          buf_put(O, F->p + t->frag, t->frag_len);
          flag(O, ps_has(&fav_ps, j->viewer, t->id));
          buf_ch(O, ',');
          if (t->author_ix >= 0) buf_put(O, F->p + au[t->author_ix].frag, au[t->author_ix].frag_len);
          flag(O, j->kind == K_FEED || ps_has(&fol_ps, j->viewer, t->author));
          buf_lit(O, "}}");
        }
        buf_lit(O, "],\"articlesCount\":");
        buf_i64(O, x->count);
        buf_ch(O, '}');
        if (share) rc_keep(&rc, j, sl, O->p, O->n, 200);
        else reply_ok(d, j, O);
        break;
      }
      case K_ARTICLE_SLUG: case K_ARTICLE_ID: {
        int ix = -1;
        if (j->kind == K_ARTICLE_ID) ix = m64_get(&artm, j->id);
        else {
          sent *e = ms_slot(&slugm, j->s1, j->l1);
          if (e->s) ix = e->v;
        }
        if (ix < 0 || !arts[ix].slug || !arts[ix].body) {
          job_error(j, 404, "not found");
          break;
        }
        art_t *t = &arts[ix];
        bool share = !j->close && !ps_has(&fav_ps, j->viewer, t->id) && !ps_has(&fol_ps, j->viewer, t->author);
        if (share && rc_reuse(&rc, j, ((uint64_t)K_ARTICLE_SLUG << 32) | (uint64_t)ix, (uint64_t)j->status_hint, &sl)) break;
        buf_lit(O, "{\"article\":{\"body\":\"");
        buf_json(O, t->body, t->bl);
        buf_lit(O, "\",");
        buf_put(O, F->p + t->frag, t->frag_len);
        flag(O, ps_has(&fav_ps, j->viewer, t->id));
        buf_ch(O, ',');
        if (t->author_ix >= 0) buf_put(O, F->p + au[t->author_ix].frag, au[t->author_ix].frag_len);
        flag(O, ps_has(&fol_ps, j->viewer, t->author));
        buf_lit(O, "}}}");
        if (share) rc_keep(&rc, j, sl, O->p, O->n, j->status_hint ? j->status_hint : 200);
        else reply_ok(d, j, O);
        break;
      }
      case K_COMMENTS: {
        bool share = !j->close;
        for (cmt_t *m = threads[x->thread].first; m && share && j->viewer; m = m->next)
          if (ps_has(&fol_ps, j->viewer, m->author)) share = false;
        if (share && rc_reuse(&rc, j, ((uint64_t)K_COMMENTS << 32) | (uint64_t)x->thread, 0, &sl)) break;
        buf_lit(O, "{\"comments\":[");
        bool first = true;
        for (cmt_t *m = threads[x->thread].first; m; m = m->next) {
          if (!m->frag_len) {
            m->frag = F->n;
            buf_lit(F, "{\"id\":");
            buf_i64(F, m->id);
            buf_lit(F, ",\"createdAt\":");
            buf_ts(F, m->created);
            buf_lit(F, ",\"updatedAt\":");
            buf_ts(F, m->updated);
            buf_lit(F, ",\"body\":\"");
            buf_json(F, m->body, m->bl);
            buf_lit(F, "\",");
            m->frag_len = F->n - m->frag;
            m->author_ix = m64_get(&aum, m->author);
          }
          if (m->author_ix < 0) continue;
          if (!first) buf_ch(O, ',');
          first = false;
          buf_put(O, F->p + m->frag, m->frag_len);
          buf_put(O, F->p + au[m->author_ix].frag, au[m->author_ix].frag_len);
          flag(O, ps_has(&fol_ps, j->viewer, m->author));
          buf_lit(O, "}}");
        }
        buf_lit(O, "]}");
        if (share) rc_keep(&rc, j, sl, O->p, O->n, 200);
        else reply_ok(d, j, O);
        break;
      }
      default:
        job_error(j, 500, "internal error");
    }
    jobs[i] = NULL;
  }
  rc_release(&rc);
  return B_OK;
}

// ---- the queue: three lanes. Feeds are the costliest read and comments the next, so nothing waits behind them, and
// each lane starts a drain at most once per gap. A free connection goes to the lane whose oldest read has waited longest.
enum { LANE_SHARED, LANE_FEED, LANE_COMMENT, NLANES };
typedef struct {
  job *head, *tail;
  int n, inflight;
  int64_t next_start, gap;
} lane_t;
static lane_t lanes[NLANES];
static pthread_mutex_t q_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_cv;
static int waiting, inflight, read_cap = 6, lane_on = 1;
#define MAX_BATCH 4096

void read_enqueue(job *j) {
  j->next = NULL;
  j->t_in = now_us();
  lane_t *l = &lanes[lane_on ? (j->kind == K_FEED ? LANE_FEED : j->kind == K_COMMENTS ? LANE_COMMENT : LANE_SHARED) : LANE_SHARED];
  pthread_mutex_lock(&q_mu);
  if (l->tail) l->tail->next = j;
  else l->head = j;
  l->tail = j;
  l->n++;
  if (l->n == 1 && waiting) pthread_cond_signal(&q_cv);
  pthread_mutex_unlock(&q_mu);
}

static int take(job **out, int *lane_out) {
  pthread_mutex_lock(&q_mu);
  for (;;) {
    int64_t now = now_us(), wake = 0;
    lane_t *best = NULL;
    if (inflight < read_cap) {
      for (int i = 0; i < NLANES; i++) {
        lane_t *l = &lanes[i];
        if (!l->n) continue;
        if (now < l->next_start) {
          if (!wake || l->next_start < wake) wake = l->next_start;
          continue;
        }
        if (!best || l->head->t_in < best->head->t_in) best = l;
      }
    }
    if (best) {
      best->next_start = now + best->gap;
      int n = 0;
      while (best->head && n < MAX_BATCH) {
        out[n++] = best->head;
        best->head = best->head->next;
      }
      if (!best->head) best->tail = NULL;
      best->n -= n;
      best->inflight++;
      inflight++;
      *lane_out = (int)(best - lanes);
      if (waiting) pthread_cond_signal(&q_cv);
      pthread_mutex_unlock(&q_mu);
      return n;
    }
    waiting++;
    if (wake) {
      struct timespec ts;
      clock_gettime(CLOCK_MONOTONIC, &ts);
      ts.tv_nsec += (wake - now) * 1000;
      ts.tv_sec += ts.tv_nsec / 1000000000;
      ts.tv_nsec %= 1000000000;
      pthread_cond_timedwait(&q_cv, &q_mu, &ts);
    } else {
      pthread_cond_wait(&q_cv, &q_mu);
    }
    waiting--;
  }
}

static void take_done(int lane) {
  pthread_mutex_lock(&q_mu);
  lanes[lane].inflight--;
  inflight--;
  if (waiting) pthread_cond_signal(&q_cv);
  pthread_mutex_unlock(&q_mu);
}

// Up to a second of tries; a batch that still has no connection is answered 500 rather than left hanging.
static void pg_reconnect(drain_t *d) {
  pg_close(&d->pg);
  for (int i = 0; i < 5 && !pg_connect(&d->pg, SETTINGS, NSETTINGS, READ_STMTS, NSTMTS); i++) {
    struct timespec ts = {0, 200000000};
    nanosleep(&ts, NULL);
  }
}

// Runs jobs with failure handling. A statement error retries each job alone, so one request can't fail others; a lost
// connection reconnects and retries; a job alone that keeps failing is answered 500.
static void run_safe(drain_t *d, job **jobs, int n) {
  for (int attempt = 0;; attempt++) {
    int rc;
    d->a.fail = &d->fail;
    int jr = setjmp(d->fail);
    if (jr == 0) {
      rc = run_batch(d, jobs, n);
    } else {  // out of arena: the wire is mid-message
      pg_reconnect(d);
      rc = B_SQL;
    }
    if (rc == B_OK) return;
    if (rc == B_LOST) pg_reconnect(d);
    else d->pg.out.n = 0;
    int left = 0;
    for (int i = 0; i < n; i++)
      if (jobs[i]) left++;
    if (!left) return;
    if (rc == B_SQL || attempt >= 3) {
      if (left == 1 || attempt >= 3) {
        for (int i = 0; i < n; i++)
          if (jobs[i]) {
            job_error(jobs[i], 500, "internal error");
            jobs[i] = NULL;
          }
        return;
      }
      for (int i = 0; i < n; i++) {
        if (!jobs[i]) continue;
        job *one[1] = {jobs[i]};
        jobs[i] = NULL;
        run_safe(d, one, 1);
      }
      return;
    }
  }
}

static void *drain_main(void *arg) {
  drain_t *d = arg;
  pthread_setname_np(pthread_self(), "c-drain");
  const char *pol = getenv("DRAIN_SCHED");
  thread_sched(pol ? pol : "batch", 0);
  arena_init(&d->a, (size_t)4 << 30);
  pg_reconnect(d);
  job **batch = malloc(sizeof(job *) * MAX_BATCH);
  for (;;) {
    int lane, n = take(batch, &lane);
    // Clients that hung up while queued cost nothing more: their jobs go straight back to be freed.
    for (int i = 0; i < n; i++)
      if (!conn_alive(batch[i])) {
        free(batch[i]->resp);  // a login's scratch; it hasn't reached the hasher in this path
        batch[i]->resp = NULL;
        loop_post(batch[i]);
        batch[i] = NULL;
      }
    run_safe(d, batch, n);
    take_done(lane);
  }
  return NULL;
}

void reads_start(int n) {
  pthread_condattr_t ca;
  pthread_condattr_init(&ca);
  pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
  pthread_cond_init(&q_cv, &ca);
  const char *e;
  lanes[LANE_SHARED].gap = (e = getenv("GAP_SHARED_US")) ? atoll(e) : 80000;
  lanes[LANE_FEED].gap = (e = getenv("GAP_FEED_US")) ? atoll(e) : 80000;
  lanes[LANE_COMMENT].gap = (e = getenv("GAP_COMMENT_US")) ? atoll(e) : 100000;
  if ((e = getenv("HUB_EST"))) hub_est = atoll(e);
  if ((e = getenv("READ_CAP"))) read_cap = atoi(e);
  if ((e = getenv("READ_LANES"))) lane_on = atoi(e);
  for (int i = 0; i < n; i++) {
    drain_t *d = calloc(1, sizeof *d);
    d->id = i;
    d->pg.fd = -1;
    pthread_t t;
    pthread_create(&t, NULL, drain_main, d);
  }
}
