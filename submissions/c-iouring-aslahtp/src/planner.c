/* The drain's read planner. Planned reads from every worker wait briefly in one queue; a batch of them becomes
 * a plan that runs in two round trips on one Postgres connection:
 *
 *   phase A: one statement per family present (global, tag, author and favorited pages and counts, feed pages
 *            and counts, articles by slug, comments, profiles, tags). Keys are deduplicated first: one page per
 *            distinct (filter, limit, offset), one count per distinct filter, one lookup per distinct slug or
 *            username. Pages come back as lean article rows.
 *   phase B: every distinct article in the batch is enriched once (tag ids, favorites count), every distinct
 *            author is read once, the tag dictionary (all tags in name order) turns tag ids into names, and one
 *            statement answers every viewer's favorited/following questions with a primary-key range scan per
 *            viewer instead of a probe per article.
 *
 * Nothing outlives the plan: all results are thrown away once its responses are rendered. Responses are the
 * finished JSON bodies, sent back to the workers. */
#include "plan.h"

#include <time.h>

#include "arena.h"
#include "ipc.h"
#include "json_out.h"
#include "pg_wire.h"
#include "sql.h"
#include "worker.h"

void drain_reply(int worker, uint32_t kind, uint64_t token, const void *data, uint32_t len);

/* ---- waiting requests ---- */

struct preq {
    struct preq *next;
    int worker;
    uint64_t token;
    int64_t t_us;          /* arrival */
    uint32_t e1, e2;       /* entries: the page or lookup, and the count */
    struct plan_req r;     /* followed by the key */
};

static struct preq *wait_head, *wait_tail;
static uint32_t wait_n;

static int64_t mono_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

void planner_add(int worker, uint64_t token, const struct plan_req *pr, uint32_t len) {
    if (len < sizeof *pr || len - sizeof *pr < pr->keylen) die("planner: malformed request");
    struct preq *q = xmalloc(sizeof *q + pr->keylen);
    q->next = NULL;
    q->worker = worker;
    q->token = token;
    q->t_us = mono_us();
    memcpy(&q->r, pr, sizeof *pr + pr->keylen);
    if (wait_tail) wait_tail->next = q;
    else wait_head = q;
    wait_tail = q;
    wait_n++;
}

int64_t planner_due_in(int64_t now_us, int64_t wait_us) {
    if (!wait_head) return -1;
    if (wait_n >= cfg.plan_max) return 0;
    int64_t due = wait_head->t_us + wait_us - now_us;
    return due > 0 ? due : 0;
}

/* ---- plan data ---- */

struct pstr {
    const char *p;  /* NULL: SQL NULL */
    uint32_t n;
};

/* Families of phase A keys, each answered by one statement. */
enum fam { F_GP, F_TP, F_AP, F_FP, F_FEP, F_TC, F_AC, F_FC, F_FEC, F_ART, F_CMT, F_PROF, F_NFAM };
static const enum stmt fam_stmt[F_NFAM] = {
    P_GLOBAL_PAGES, P_TAG_PAGES, P_AUTHOR_PAGES, P_FAV_PAGES, P_FEED, P_TAG_COUNTS,
    P_AUTHOR_COUNTS, P_FAV_COUNTS, P_FEED, P_ARTICLES, P_COMMENTS, P_PROFILES,  /* F_FEP and F_FEC share P_FEED */
};

struct entry {
    uint8_t fam;
    bool found;
    int64_t a, b, c;          /* numeric key: (limit, offset) or (viewer, limit, offset) */
    struct pstr s;            /* string key */
    int64_t count;            /* counts */
    uint32_t *items, n, cap;  /* pages: article indices; comments: comment indices */
    int32_t art;              /* F_ART: article index, -1 if none */
    int64_t uid;              /* F_PROF */
    struct pstr username, bio, image;
};

struct art {
    int64_t id, author_id, created, updated, favcount;
    struct pstr slug, title, description, body, tags_json, username, bio, image;
    int32_t *tag_ids;         /* from P_ARTX; rendered into tags_json once the dictionary is in */
    uint32_t ntag_ids;
    bool has_body, enriched;
};

struct author {
    int64_t id;
    struct pstr username, bio, image;
};

struct cmt {
    int64_t id, author_id, created, updated;
    struct pstr body, username, bio, image;
};

/* Open-addressing map from a key to a small integer. */
struct mkey {
    uint8_t kind;
    int64_t a, b, c;
    const char *s;
    uint32_t n;
};
struct map {
    uint32_t *slot;        /* value + 1, or 0 */
    struct mkey *keys;     /* by value */
    uint32_t cap;          /* slots, a power of two */
    uint32_t n, kcap;      /* values handed out; room in keys */
};

struct plan {
    struct arena a;
    struct preq *reqs;
    uint32_t nreq;
    int phase;
    enum stmt sent[F_NFAM + 4];
    int nsent, cur;
    bool failed;

    struct entry *ents;
    uint32_t nents, ents_cap;
    uint32_t *fam_list[F_NFAM];  /* entry indices in ordinal order (k - 1) */
    uint32_t fam_n[F_NFAM], fam_cap[F_NFAM];
    struct map emap;

    struct art *arts;
    uint32_t narts, arts_cap;
    struct map amap;
    struct cmt *cmts;
    uint32_t ncmts, cmts_cap;
    struct map flags;            /* kind 0: (viewer, article) favorited; kind 1: (viewer, user) followed */

    struct author *authors;      /* P_AUTHORS rows, found by id through umap */
    uint32_t nauthors, authors_cap;
    struct map umap;

    bool want_count, want_tags;
    int64_t global_count;
    struct pstr *tags;           /* every tag name in name order (P_TAGDICT) */
    int32_t *tag_id;             /* tags[i]'s id */
    uint32_t ntags, tags_cap, tag_id_cap;
    struct buf body;
};

#define GROW(arr, n, cap)                                             \
    do {                                                              \
        if ((n) == (cap)) {                                           \
            (cap) = (cap) ? (cap) * 2 : 16;                           \
            (arr) = xrealloc((arr), (size_t)(cap) * sizeof *(arr));   \
        }                                                             \
    } while (0)

static uint64_t mkey_hash(const struct mkey *k) {
    uint64_t h = 1469598103934665603ull ^ k->kind;
    h = (h ^ (uint64_t)k->a) * 1099511628211ull;
    h = (h ^ (uint64_t)k->b) * 1099511628211ull;
    h = (h ^ (uint64_t)k->c) * 1099511628211ull;
    for (uint32_t i = 0; i < k->n; i++) h = (h ^ (uint8_t)k->s[i]) * 1099511628211ull;
    return h ^ (h >> 29);
}

static bool mkey_eq(const struct mkey *x, const struct mkey *y) {
    return x->kind == y->kind && x->a == y->a && x->b == y->b && x->c == y->c && x->n == y->n &&
           (x->n == 0 || memcmp(x->s, y->s, x->n) == 0);
}

static void map_init(struct map *m, uint32_t expect) {
    m->cap = 64;
    while (m->cap < expect * 2) m->cap *= 2;
    m->slot = xcalloc(m->cap, sizeof *m->slot);
    m->keys = NULL;
    m->n = m->kcap = 0;
}

static void map_free(struct map *m) {
    free(m->slot);
    free(m->keys);
}

/* The value for k; a new key gets the next value (0, 1, ...), and *added says so. */
static uint32_t map_get(struct map *m, const struct mkey *k, bool *added) {
    uint32_t nvals = m->n;
    if (nvals * 2 >= m->cap) {
        uint32_t ncap = m->cap * 2;
        uint32_t *ns = xcalloc(ncap, sizeof *ns);
        for (uint32_t v = 0; v < nvals; v++) {
            uint64_t h = mkey_hash(&m->keys[v]);
            uint32_t i = (uint32_t)h & (ncap - 1);
            while (ns[i]) i = (i + 1) & (ncap - 1);
            ns[i] = v + 1;
        }
        free(m->slot);
        m->slot = ns;
        m->cap = ncap;
    }
    uint32_t i = (uint32_t)mkey_hash(k) & (m->cap - 1);
    while (m->slot[i]) {
        uint32_t v = m->slot[i] - 1;
        if (mkey_eq(&m->keys[v], k)) {
            *added = false;
            return v;
        }
        i = (i + 1) & (m->cap - 1);
    }
    GROW(m->keys, nvals, m->kcap);
    m->keys[nvals] = *k;
    m->slot[i] = nvals + 1;
    m->n++;
    *added = true;
    return nvals;
}

static bool map_has(const struct map *m, const struct mkey *k) {
    uint32_t i = (uint32_t)mkey_hash(k) & (m->cap - 1);
    while (m->slot[i]) {
        if (mkey_eq(&m->keys[m->slot[i] - 1], k)) return true;
        i = (i + 1) & (m->cap - 1);
    }
    return false;
}

static struct pstr keep(struct plan *p, const uint8_t *v, int32_t n) {
    if (n < 0) return (struct pstr){NULL, 0};
    char *d = arena_alloc(&p->a, (size_t)n + 1);
    memcpy(d, v, (size_t)n);
    return (struct pstr){d, (uint32_t)n};
}

/* ---- phase A: keys ---- */

static uint32_t entry_for(struct plan *p, enum fam f, int64_t a, int64_t b, int64_t c, const char *s, uint32_t n) {
    struct mkey k = {(uint8_t)f, a, b, c, s, n};
    bool added;
    uint32_t e = map_get(&p->emap, &k, &added);
    if (!added) return e;
    GROW(p->ents, p->nents, p->ents_cap);
    struct entry *en = &p->ents[p->nents++];
    memset(en, 0, sizeof *en);
    en->fam = (uint8_t)f;
    en->a = a, en->b = b, en->c = c;
    en->s = (struct pstr){s, n};
    en->art = -1;
    GROW(p->fam_list[f], p->fam_n[f], p->fam_cap[f]);
    p->fam_list[f][p->fam_n[f]++] = e;
    return e;
}

static void add_req(struct plan *p, struct preq *q) {
    const struct plan_req *r = &q->r;
    const char *key = r->key;
    uint32_t kl = r->keylen;
    static const enum fam page_fam[4] = {F_GP, F_TP, F_AP, F_FP}, count_fam[4] = {F_GP, F_TC, F_AC, F_FC};
    q->e1 = q->e2 = UINT32_MAX;
    switch (r->kind) {
    case PK_LIST:
        if (r->filter == PF_NONE) {
            q->e1 = entry_for(p, F_GP, r->limit, r->offset, 0, NULL, 0);
            p->want_count = true;
        } else {
            q->e1 = entry_for(p, page_fam[r->filter], r->limit, r->offset, 0, key, kl);
            q->e2 = entry_for(p, count_fam[r->filter], 0, 0, 0, key, kl);
        }
        break;
    case PK_FEED:
        q->e1 = entry_for(p, F_FEP, r->viewer, r->limit, r->offset, NULL, 0);
        q->e2 = entry_for(p, F_FEC, r->viewer, 0, 0, NULL, 0);
        break;
    case PK_ARTICLE: q->e1 = entry_for(p, F_ART, 0, 0, 0, key, kl); break;
    case PK_COMMENTS: q->e1 = entry_for(p, F_CMT, 0, 0, 0, key, kl); break;
    case PK_PROFILE: q->e1 = entry_for(p, F_PROF, 0, 0, 0, key, kl); break;
    case PK_TAGS: p->want_tags = true; break;
    default: die("planner: unknown request kind %u", r->kind);
    }
}

static void bind_text_array(struct pg_bind *pb, struct plan *p, enum fam f) {
    size_t at;
    pg_bind_array_begin(pb, OID_TEXT, &at);
    for (uint32_t i = 0; i < p->fam_n[f]; i++) {
        const struct entry *e = &p->ents[p->fam_list[f][i]];
        pg_bind_array_text(pb, e->s.p, e->s.n);
    }
    pg_bind_array_end(pb, at, p->fam_n[f], false);
}

/* field: 0 = a, 1 = b, 2 = c */
static void bind_i64_array(struct pg_bind *pb, struct plan *p, enum fam f, int field) {
    size_t at;
    pg_bind_array_begin(pb, OID_INT8, &at);
    for (uint32_t i = 0; i < p->fam_n[f]; i++) {
        const struct entry *e = &p->ents[p->fam_list[f][i]];
        pg_bind_array_i64(pb, field == 0 ? e->a : field == 1 ? e->b : e->c);
    }
    pg_bind_array_end(pb, at, p->fam_n[f], false);
}

static void stmt_start(struct plan *p, struct pg_bind *pb, struct buf *out, enum stmt s) {
    p->sent[p->nsent++] = s;
    pg_bind_begin(pb, out, stmt_names[s]);
}

static void stmt_end(struct pg_bind *pb) {
    pg_bind_end(pb);
    pg_execute(pb->b);
}

static void write_phase_a(struct plan *p, struct buf *out) {
    struct pg_bind pb;
    p->nsent = p->cur = 0;
    for (int f = 0; f < F_NFAM; f++) {
        if (!p->fam_n[f] || f == F_FEC) continue;  /* feed counts ride in P_FEED with the feed pages */
        stmt_start(p, &pb, out, fam_stmt[f]);
        switch (f) {
        case F_GP:
            bind_i64_array(&pb, p, f, 0);
            bind_i64_array(&pb, p, f, 1);
            break;
        case F_TP: case F_AP: case F_FP:
            bind_text_array(&pb, p, f);
            bind_i64_array(&pb, p, f, 0);
            bind_i64_array(&pb, p, f, 1);
            break;
        case F_FEP:  /* every feed request has both a page and a count entry */
            bind_i64_array(&pb, p, F_FEC, 0);
            bind_i64_array(&pb, p, f, 0);
            bind_i64_array(&pb, p, f, 1);
            bind_i64_array(&pb, p, f, 2);
            break;
        default:  /* counts by name, slugs, usernames */
            bind_text_array(&pb, p, f);
            break;
        }
        stmt_end(&pb);
    }
    if (p->want_count) {
        stmt_start(p, &pb, out, P_GLOBAL_COUNT);
        stmt_end(&pb);
    }
    if (p->want_tags) {
        stmt_start(p, &pb, out, P_TAGDICT);
        stmt_end(&pb);
    }
    pg_sync(out);
}

struct plan *planner_start(struct buf *out) {
    if (!wait_head) return NULL;
    struct plan *p = xcalloc(1, sizeof *p);
    arena_init(&p->a, 1 << 16);
    uint32_t n = wait_n < cfg.plan_max ? wait_n : cfg.plan_max;
    p->reqs = wait_head;
    struct preq *last = wait_head;
    for (uint32_t i = 1; i < n; i++) last = last->next;
    wait_head = last->next;
    if (!wait_head) wait_tail = NULL;
    last->next = NULL;
    wait_n -= n;
    p->nreq = n;

    map_init(&p->emap, n * 2);
    map_init(&p->amap, n * 4);
    for (struct preq *q = p->reqs; q; q = q->next) add_req(p, q);
    buf_init(&p->body, 4096);
    write_phase_a(p, out);
    return p;
}

/* ---- phase A: rows ---- */

struct cols {
    const uint8_t *v[SQL_MAX_COLS];
    int32_t n[SQL_MAX_COLS];
};

static bool row_cols(const struct pg_msg *m, struct cols *c, int want) {
    struct pg_row row;
    if (!pg_row_init(&row, m) || row.ncols != want) return false;
    for (int i = 0; i < want; i++) {
        c->n[i] = pg_col(&row, &c->v[i]);
        if (c->n[i] == -2) return false;
    }
    return true;
}

static int64_t i64(const struct cols *c, int i) { return c->n[i] == 8 ? pg_i64(c->v[i]) : 0; }

/* One P_TAGDICT row (id, name): the tags come in name order, so the list doubles as the /api/tags answer. */
static bool tag_row(struct plan *p, const struct pg_msg *m) {
    struct cols c;
    if (!row_cols(m, &c, 2) || c.n[0] != 4) return false;
    GROW(p->tags, p->ntags, p->tags_cap);
    if (p->tag_id_cap < p->tags_cap) {
        p->tag_id_cap = p->tags_cap;
        p->tag_id = xrealloc(p->tag_id, p->tag_id_cap * sizeof *p->tag_id);
    }
    p->tag_id[p->ntags] = pg_i32(c.v[0]);
    p->tags[p->ntags++] = keep(p, c.v[1], c.n[1]);
    return true;
}

/* The article for a lean row (k, id, author_id, slug, title, description, created_at, updated_at[, body]). */
static uint32_t art_from_row(struct plan *p, const struct cols *c, bool with_body) {
    struct mkey k = {0, i64(c, 1), 0, 0, NULL, 0};
    bool added;
    uint32_t i = map_get(&p->amap, &k, &added);
    if (added) {
        GROW(p->arts, p->narts, p->arts_cap);
        struct art *a = &p->arts[p->narts++];
        memset(a, 0, sizeof *a);
        a->id = i64(c, 1);
        a->author_id = i64(c, 2);
        a->slug = keep(p, c->v[3], c->n[3]);
        a->title = keep(p, c->v[4], c->n[4]);
        a->description = keep(p, c->v[5], c->n[5]);
        a->created = i64(c, 6);
        a->updated = i64(c, 7);
    }
    struct art *a = &p->arts[i];
    if (with_body && !a->has_body) {
        a->body = keep(p, c->v[8], c->n[8]);
        a->has_body = true;
    }
    return i;
}

static struct entry *entry_k(struct plan *p, enum fam f, int64_t k) {
    if (k < 1 || (uint64_t)k > p->fam_n[f]) return NULL;
    return &p->ents[p->fam_list[f][k - 1]];
}

static enum fam stmt_fam(enum stmt s) {
    for (int f = 0; f < F_NFAM; f++)
        if (fam_stmt[f] == s) return (enum fam)f;
    return F_NFAM;
}

static bool row_phase_a(struct plan *p, enum stmt s, const struct pg_msg *m) {
    struct cols c;
    enum fam f = stmt_fam(s);
    switch (s) {
    case P_FEED: {
        /* Count rows carry -k (k: the viewer's F_FEC ordinal), page rows k (the request's F_FEP ordinal). */
        if (!row_cols(m, &c, 8)) return false;
        int64_t k = i64(&c, 0);
        if (k < 0) {
            struct entry *e = entry_k(p, F_FEC, -k);
            if (!e) return false;
            e->count = i64(&c, 1);
            return true;
        }
        struct entry *e = entry_k(p, F_FEP, k);
        if (!e) return false;
        uint32_t ai = art_from_row(p, &c, false);
        GROW(e->items, e->n, e->cap);
        e->items[e->n++] = ai;
        return true;
    }
    case P_GLOBAL_PAGES: case P_TAG_PAGES: case P_AUTHOR_PAGES: case P_FAV_PAGES: {
        if (!row_cols(m, &c, 8)) return false;
        struct entry *e = entry_k(p, f, i64(&c, 0));
        if (!e) return false;
        uint32_t ai = art_from_row(p, &c, false);
        GROW(e->items, e->n, e->cap);
        e->items[e->n++] = ai;
        return true;
    }
    case P_TAG_COUNTS: case P_AUTHOR_COUNTS: case P_FAV_COUNTS: {
        if (!row_cols(m, &c, 2)) return false;
        struct entry *e = entry_k(p, f, i64(&c, 0));
        if (!e) return false;
        e->count = i64(&c, 1);
        return true;
    }
    case P_GLOBAL_COUNT:
        if (!row_cols(m, &c, 1)) return false;
        p->global_count = i64(&c, 0);
        return true;
    case P_ARTICLES: {
        if (!row_cols(m, &c, 9)) return false;
        struct entry *e = entry_k(p, f, i64(&c, 0));
        if (!e) return false;
        e->art = (int32_t)art_from_row(p, &c, true);
        return true;
    }
    case P_COMMENTS: {
        if (!row_cols(m, &c, 10)) return false;
        struct entry *e = entry_k(p, f, i64(&c, 0));
        if (!e) return false;
        e->found = true;
        if (c.n[2] < 0) return true;  /* the article has no comments */
        GROW(p->cmts, p->ncmts, p->cmts_cap);
        struct cmt *x = &p->cmts[p->ncmts];
        x->id = i64(&c, 2);
        x->body = keep(p, c.v[3], c.n[3]);
        x->created = i64(&c, 4);
        x->updated = i64(&c, 5);
        x->author_id = i64(&c, 6);
        x->username = keep(p, c.v[7], c.n[7]);
        x->bio = keep(p, c.v[8], c.n[8]);
        x->image = keep(p, c.v[9], c.n[9]);
        GROW(e->items, e->n, e->cap);
        e->items[e->n++] = p->ncmts++;
        return true;
    }
    case P_PROFILES: {
        if (!row_cols(m, &c, 5)) return false;
        struct entry *e = entry_k(p, f, i64(&c, 0));
        if (!e) return false;
        e->found = true;
        e->uid = i64(&c, 1);
        e->username = keep(p, c.v[2], c.n[2]);
        e->bio = keep(p, c.v[3], c.n[3]);
        e->image = keep(p, c.v[4], c.n[4]);
        return true;
    }
    case P_TAGDICT:
        return tag_row(p, m);
    default:
        return false;
    }
}

/* ---- phase B ---- */

static const struct art *P_ARTS;  /* for the sort comparators */
static const struct cmt *P_CMTS;

static int by_id_desc(const void *x, const void *y) {
    int64_t a = P_ARTS[*(const uint32_t *)x].id, b = P_ARTS[*(const uint32_t *)y].id;
    return a < b ? 1 : a > b ? -1 : 0;
}

static int by_comment_order(const void *x, const void *y) {
    const struct cmt *a = &P_CMTS[*(const uint32_t *)x], *b = &P_CMTS[*(const uint32_t *)y];
    if (a->created != b->created) return a->created < b->created ? 1 : -1;
    return a->id < b->id ? 1 : a->id > b->id ? -1 : 0;
}

struct pairs {
    int64_t *v, *x;
    uint32_t n, cap;
};

static void want_flag(struct plan *p, struct pairs *pr, uint8_t kind, int64_t viewer, int64_t x) {
    struct mkey k = {kind, viewer, x, 0, NULL, 0};
    bool added;
    map_get(&p->flags, &k, &added);
    if (!added) return;
    if (pr->n == pr->cap) {
        pr->cap = pr->cap ? pr->cap * 2 : 64;
        pr->v = xrealloc(pr->v, pr->cap * sizeof *pr->v);
        pr->x = xrealloc(pr->x, pr->cap * sizeof *pr->x);
    }
    pr->v[pr->n] = viewer;
    pr->x[pr->n++] = x;
}

static void bind_vec(struct pg_bind *pb, const int64_t *v, uint32_t n) { pg_bind_i64_array(pb, v, n); }

/* Writes phase B; false if nothing needs it. */
static bool write_phase_b(struct plan *p, struct buf *out) {
    struct pg_bind pb;
    P_ARTS = p->arts;
    P_CMTS = p->cmts;
    for (uint32_t i = 0; i < p->nents; i++) {
        struct entry *e = &p->ents[i];
        if (e->fam <= F_FEP && e->n > 1) qsort(e->items, e->n, sizeof *e->items, by_id_desc);
        if (e->fam == F_CMT && e->n > 1) qsort(e->items, e->n, sizeof *e->items, by_comment_order);
    }

    /* Which flags each viewer needs. The two kinds share one map but are sent as two pair lists. */
    struct pairs fav = {0}, fol = {0};
    map_init(&p->flags, 256);
    for (struct preq *q = p->reqs; q; q = q->next) {
        int64_t v = q->r.viewer;
        if (!v || q->e1 == UINT32_MAX) continue;
        struct entry *e = &p->ents[q->e1];
        switch (q->r.kind) {
        case PK_LIST: case PK_FEED:
            for (uint32_t i = 0; i < e->n; i++) {
                want_flag(p, &fav, 0, v, p->arts[e->items[i]].id);
                want_flag(p, &fol, 1, v, p->arts[e->items[i]].author_id);
            }
            break;
        case PK_ARTICLE:
            if (e->art >= 0) {
                want_flag(p, &fav, 0, v, p->arts[e->art].id);
                want_flag(p, &fol, 1, v, p->arts[e->art].author_id);
            }
            break;
        case PK_COMMENTS:
            for (uint32_t i = 0; i < e->n; i++) want_flag(p, &fol, 1, v, p->cmts[e->items[i]].author_id);
            break;
        case PK_PROFILE:
            if (e->found) want_flag(p, &fol, 1, v, e->uid);
            break;
        }
    }

    p->nsent = p->cur = 0;
    if (p->narts) {
        /* Articles once each, their authors once each, then the tag dictionary: it comes after P_ARTX, so every
         * tag id P_ARTX returns is in it (tags are never deleted). It also answers this plan's /api/tags. */
        int64_t *ids = xmalloc(p->narts * sizeof *ids), *authors = xmalloc(p->narts * sizeof *authors);
        uint32_t nau = 0;
        struct map seen;
        map_init(&seen, p->narts);
        for (uint32_t i = 0; i < p->narts; i++) {
            ids[i] = p->arts[i].id;
            struct mkey k = {0, p->arts[i].author_id, 0, 0, NULL, 0};
            bool added;
            map_get(&seen, &k, &added);
            if (added) authors[nau++] = p->arts[i].author_id;
        }
        map_free(&seen);
        stmt_start(p, &pb, out, P_ARTX);
        bind_vec(&pb, ids, p->narts);
        stmt_end(&pb);
        stmt_start(p, &pb, out, P_AUTHORS);
        bind_vec(&pb, authors, nau);
        stmt_end(&pb);
        stmt_start(p, &pb, out, P_TAGDICT);
        stmt_end(&pb);
        p->ntags = 0;  /* phase A's copy, if any, is replaced by this newer one */
        map_init(&p->umap, nau);
        free(ids);
        free(authors);
    }
    /* The flag answers replace the question set: the map is rebuilt from the true pairs only. */
    map_free(&p->flags);
    map_init(&p->flags, (fav.n + fol.n) / 2 + 16);
    if (fav.n || fol.n) {
        stmt_start(p, &pb, out, P_FLAGS);
        bind_vec(&pb, fav.v, fav.n);
        bind_vec(&pb, fav.x, fav.n);
        bind_vec(&pb, fol.v, fol.n);
        bind_vec(&pb, fol.x, fol.n);
        stmt_end(&pb);
    }
    free(fav.v), free(fav.x), free(fol.v), free(fol.x);
    if (!p->nsent) return false;
    pg_sync(out);
    return true;
}

static bool row_phase_b(struct plan *p, enum stmt s, const struct pg_msg *m) {
    struct cols c;
    if (s == P_ARTX) {
        if (!row_cols(m, &c, 3)) return false;
        struct mkey k = {0, i64(&c, 0), 0, 0, NULL, 0};
        bool added;
        uint32_t i = map_get(&p->amap, &k, &added);
        if (added) return false;  /* not an article we asked about */
        struct art *a = &p->arts[i];
        a->ntag_ids = 0;
        if (c.n[1] >= 0) {
            struct pg_array arr;
            if (!pg_array_init(&arr, c.v[1], c.n[1])) return false;
            a->tag_ids = arena_alloc(&p->a, (arr.n ? arr.n : 1) * sizeof *a->tag_ids);
            for (uint32_t j = 0; j < arr.n; j++) {
                const uint8_t *v;
                int32_t n = pg_array_next(&arr, &v);
                if (n == 4) a->tag_ids[a->ntag_ids++] = pg_i32(v);
            }
        }
        a->favcount = i64(&c, 2);
        a->enriched = true;
        return true;
    }
    if (s == P_AUTHORS) {
        if (!row_cols(m, &c, 4)) return false;
        struct mkey k = {0, i64(&c, 0), 0, 0, NULL, 0};
        bool added;
        map_get(&p->umap, &k, &added);
        if (!added) return true;
        GROW(p->authors, p->nauthors, p->authors_cap);
        struct author *u = &p->authors[p->nauthors++];
        u->id = k.a;
        u->username = keep(p, c.v[1], c.n[1]);
        u->bio = keep(p, c.v[2], c.n[2]);
        u->image = keep(p, c.v[3], c.n[3]);
        return true;
    }
    if (s == P_TAGDICT) return tag_row(p, m);
    if (s == P_FLAGS) {
        if (!row_cols(m, &c, 3)) return false;
        struct mkey k = {(uint8_t)i64(&c, 0), i64(&c, 1), i64(&c, 2), 0, NULL, 0};
        bool added;
        map_get(&p->flags, &k, &added);
        return true;
    }
    return false;
}

/* ---- rendering ---- */

static void put_pstr(struct buf *b, struct pstr s) {
    if (!s.p) buf_lit(b, "null");
    else json_str(b, s.p, s.n);
}

static bool flag(struct plan *p, uint8_t kind, int64_t viewer, int64_t x) {
    if (!viewer) return false;
    struct mkey k = {kind, viewer, x, 0, NULL, 0};
    return map_has(&p->flags, &k);
}

static void put_author(struct buf *b, struct pstr username, struct pstr bio, struct pstr image, bool following) {
    buf_lit(b, "{\"username\":");
    put_pstr(b, username);
    buf_lit(b, ",\"bio\":");
    put_pstr(b, bio);
    buf_lit(b, ",\"image\":");
    put_pstr(b, image);
    if (following) buf_lit(b, ",\"following\":true}");
    else buf_lit(b, ",\"following\":false}");
}

static void put_article(struct plan *p, struct buf *b, const struct art *a, int64_t viewer, bool body) {
    buf_lit(b, "{\"slug\":");
    put_pstr(b, a->slug);
    buf_lit(b, ",\"title\":");
    put_pstr(b, a->title);
    buf_lit(b, ",\"description\":");
    put_pstr(b, a->description);
    if (body) {
        buf_lit(b, ",\"body\":");
        put_pstr(b, a->body);
    }
    buf_lit(b, ",\"tagList\":");
    buf_put(b, a->tags_json.p, a->tags_json.n);
    buf_lit(b, ",\"createdAt\":");
    json_ts(b, a->created);
    buf_lit(b, ",\"updatedAt\":");
    json_ts(b, a->updated);
    if (flag(p, 0, viewer, a->id)) buf_lit(b, ",\"favorited\":true");
    else buf_lit(b, ",\"favorited\":false");
    buf_lit(b, ",\"favoritesCount\":");
    buf_put_i64(b, a->favcount);
    buf_lit(b, ",\"author\":");
    put_author(b, a->username, a->bio, a->image, flag(p, 1, viewer, a->author_id));
    buf_putc(b, '}');
}

static void put_error(struct buf *b, const char *msg) {
    buf_lit(b, "{\"errors\":{\"body\":[");
    json_str(b, msg, strlen(msg));
    buf_lit(b, "]}}");
}

static int render(struct plan *p, struct preq *q, struct buf *b) {
    int64_t v = q->r.viewer;
    struct entry *e = q->e1 != UINT32_MAX ? &p->ents[q->e1] : NULL;
    switch (q->r.kind) {
    case PK_LIST: case PK_FEED: {
        buf_lit(b, "{\"articles\":[");
        bool first = true;
        for (uint32_t i = 0; i < e->n; i++) {
            const struct art *a = &p->arts[e->items[i]];
            if (!a->enriched) continue;  /* deleted between the two phases */
            if (!first) buf_putc(b, ',');
            first = false;
            put_article(p, b, a, v, false);
        }
        buf_lit(b, "],\"articlesCount\":");
        buf_put_i64(b, q->e2 != UINT32_MAX ? p->ents[q->e2].count : p->global_count);
        buf_putc(b, '}');
        return 200;
    }
    case PK_ARTICLE:
        if (e->art < 0 || !p->arts[e->art].enriched) {
            put_error(b, "article not found");
            return 404;
        }
        buf_lit(b, "{\"article\":");
        put_article(p, b, &p->arts[e->art], v, true);
        buf_putc(b, '}');
        return 200;
    case PK_COMMENTS:
        if (!e->found) {
            put_error(b, "article not found");
            return 404;
        }
        buf_lit(b, "{\"comments\":[");
        for (uint32_t i = 0; i < e->n; i++) {
            const struct cmt *x = &p->cmts[e->items[i]];
            if (i) buf_putc(b, ',');
            buf_lit(b, "{\"id\":");
            buf_put_i64(b, x->id);
            buf_lit(b, ",\"createdAt\":");
            json_ts(b, x->created);
            buf_lit(b, ",\"updatedAt\":");
            json_ts(b, x->updated);
            buf_lit(b, ",\"body\":");
            put_pstr(b, x->body);
            buf_lit(b, ",\"author\":");
            put_author(b, x->username, x->bio, x->image, flag(p, 1, v, x->author_id));
            buf_putc(b, '}');
        }
        buf_lit(b, "]}");
        return 200;
    case PK_PROFILE:
        if (!e->found) {
            put_error(b, "profile not found");
            return 404;
        }
        buf_lit(b, "{\"profile\":");
        put_author(b, e->username, e->bio, e->image, flag(p, 1, v, e->uid));
        buf_putc(b, '}');
        return 200;
    case PK_TAGS:
        buf_lit(b, "{\"tags\":[");
        for (uint32_t i = 0; i < p->ntags; i++) {
            if (i) buf_putc(b, ',');
            put_pstr(b, p->tags[i]);
        }
        buf_lit(b, "]}");
        return 200;
    }
    return 500;
}

static void answer_all(struct plan *p) {
    for (struct preq *q = p->reqs; q; q = q->next) {
        struct buf *b = &p->body;
        b->len = 0;
        buf_reserve(b, sizeof(struct plan_reply));
        b->len = sizeof(struct plan_reply);
        int status;
        if (p->failed) {
            put_error(b, "internal error");
            status = 500;
        } else {
            status = render(p, q, b);
        }
        struct plan_reply *rp = (struct plan_reply *)b->p;
        rp->status = (uint16_t)status;
        rp->pad = 0;
        rp->len = (uint32_t)(b->len - sizeof *rp);
        drain_reply(q->worker, IPC_PLAN, q->token, b->p, (uint32_t)b->len);
    }
}

static void plan_free(struct plan *p) {
    struct preq *q = p->reqs;
    while (q) {
        struct preq *next = q->next;
        free(q);
        q = next;
    }
    for (uint32_t i = 0; i < p->nents; i++) free(p->ents[i].items);
    free(p->ents);
    for (int f = 0; f < F_NFAM; f++) free(p->fam_list[f]);
    map_free(&p->emap);
    map_free(&p->amap);
    if (p->flags.slot) map_free(&p->flags);
    if (p->umap.slot) map_free(&p->umap);
    free(p->arts);
    free(p->cmts);
    free(p->authors);
    free(p->tags);
    free(p->tag_id);
    buf_free(&p->body);
    arena_free(&p->a);
    free(p);
}

/* After phase B: each enriched article gets its author (an article whose author row is gone is treated as gone,
 * as the old join did) and its tags as the JSON array every response with it shares, in name order: the
 * dictionary is in name order, so a tag's position there is its rank. */
static void finish_articles(struct plan *p) {
    int32_t max_id = 0;
    for (uint32_t i = 0; i < p->ntags; i++)
        if (p->tag_id[i] > max_id) max_id = p->tag_id[i];
    int32_t *rank = xmalloc(((size_t)max_id + 1) * sizeof *rank);
    for (int32_t i = 0; i <= max_id; i++) rank[i] = -1;
    for (uint32_t i = 0; i < p->ntags; i++)
        if (p->tag_id[i] >= 0) rank[p->tag_id[i]] = (int32_t)i;

    struct buf t;
    buf_init(&t, 256);
    for (uint32_t i = 0; i < p->narts; i++) {
        struct art *a = &p->arts[i];
        if (!a->enriched) continue;
        struct mkey k = {0, a->author_id, 0, 0, NULL, 0};
        if (!map_has(&p->umap, &k)) {
            a->enriched = false;
            continue;
        }
        bool added;
        const struct author *u = &p->authors[map_get(&p->umap, &k, &added)];
        a->username = u->username;
        a->bio = u->bio;
        a->image = u->image;

        /* Ranks of this article's tags, insertion-sorted (an article usually has a handful). */
        int32_t *r = arena_alloc(&p->a, (a->ntag_ids ? a->ntag_ids : 1) * sizeof *r);
        uint32_t nr = 0;
        for (uint32_t j = 0; j < a->ntag_ids; j++) {
            int32_t id = a->tag_ids[j];
            if (id < 0 || id > max_id || rank[id] < 0) continue;
            int32_t x = rank[id];
            uint32_t at = nr++;
            while (at && r[at - 1] > x) {
                r[at] = r[at - 1];
                at--;
            }
            r[at] = x;
        }
        t.len = 0;
        buf_putc(&t, '[');
        for (uint32_t j = 0; j < nr; j++) {
            if (j) buf_putc(&t, ',');
            json_str(&t, p->tags[r[j]].p, p->tags[r[j]].n);
        }
        buf_putc(&t, ']');
        a->tags_json = keep(p, (const uint8_t *)t.p, (int32_t)t.len);
    }
    buf_free(&t);
    free(rank);
}

bool planner_msg(struct plan *p, const struct pg_msg *m, struct buf *out, bool *done) {
    *done = false;
    switch (m->type) {
    case 'D':
        if (p->failed || p->cur >= p->nsent) break;
        if (!(p->phase == 0 ? row_phase_a(p, p->sent[p->cur], m) : row_phase_b(p, p->sent[p->cur], m))) {
            fprintf(stderr, "drain: unexpected row for statement s%d\n", (int)p->sent[p->cur]);
            p->failed = true;
        }
        break;
    case 'C':
        p->cur++;
        break;
    case 'E': {
        struct pg_error e;
        pg_parse_error(m, &e);
        fprintf(stderr, "drain: plan phase %c failed: %s %s\n", p->phase ? 'B' : 'A', e.sqlstate, e.message);
        p->failed = true;
        break;
    }
    case 'Z':
        if (p->phase == 0 && !p->failed) {
            p->phase = 1;
            if (write_phase_b(p, out)) return true;
        }
        if (p->phase == 1 && !p->failed && p->narts) finish_articles(p);
        answer_all(p);
        plan_free(p);
        *done = true;
        return true;
    default:
        break;
    }
    return false;
}

void planner_init(void) {
    wait_head = wait_tail = NULL;
    wait_n = 0;
}
