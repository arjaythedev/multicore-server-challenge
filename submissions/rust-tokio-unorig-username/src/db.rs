//! Postgres: read connections fed by a batching queue, pipelined write connections, prepared statements.
//!
//! Reads of one kind that wait together go out as ONE statement: the per-request query is the inner side of
//! a LATERAL join over `unnest()` of the waiting requests' parameters, and each row carries its request's
//! ordinal `i`. Viewer-independent article data (tags, favorite count, author) is computed once per distinct
//! article in a statement; viewer flags per request. Every batched statement takes the same four arrays
//! (viewer, n1, n2, s), so one code path serves them all.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use tokio::sync::{Notify, oneshot};
use tokio_postgres::{Client, NoTls, Row, Statement};

pub struct Q {
    pub v: i64,
    pub n1: i64,
    pub n2: i64,
    pub s: String,
}

macro_rules! from_r {
    () => {
        " FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::text[]) WITH ORDINALITY AS r(v, n1, n2, s, i)"
    };
}

// The viewer-independent Article columns of `articles a`, computed once per distinct article in a statement
// however many of its requests show that article. Tag names come from primary-key lookups (1-4 per article).
macro_rules! enrich {
    ($body:literal) => {
        concat!(
            "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image",
            $body,
            " FROM articles a LEFT JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = a.author_id) u ON true"
        )
    };
}

// The Article columns of enriched `e` with the per-request flags of viewer `$v` (skipped for anonymous
// viewers); `$f` computes author.following.
macro_rules! out {
    ($v:literal, $f:literal) => {
        concat!(
            "e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, ",
            $v,
            " <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = ",
            $v,
            " AND f.article_id = e.id), e.username, e.bio, e.image, ",
            $f
        )
    };
}

// A list: i, n (capped count), then the list Article columns (NULL on an empty page). `$key` resolves the
// request's filter, `$cnt` counts from it (k.key), `$ids` orders the page's article ids, bounded by 100 first
// so the generic plan expects a small page.
macro_rules! list {
    ($key:literal, $cnt:literal, $ids:literal, $f:literal) => {
        concat!(
            "WITH k AS MATERIALIZED (SELECT r.*, ",
            $key,
            " AS key",
            from_r!(),
            "),
 c AS MATERIALIZED (SELECT k.i, (SELECT count(*) FROM (",
            $cnt,
            " LIMIT 1000) s) AS n FROM k),
 p AS MATERIALIZED (SELECT k.i, x.id FROM k CROSS JOIN LATERAL (SELECT id FROM (",
            $ids,
            " LIMIT 100 OFFSET k.n2) q ORDER BY id DESC LIMIT k.n1) x),
 e AS MATERIALIZED (",
            enrich!(""),
            " WHERE a.id = ANY(ARRAY(SELECT DISTINCT id FROM p)))
 SELECT k.i, c.n, ",
            out!("k.v", $f),
            " FROM k JOIN c ON c.i = k.i LEFT JOIN p ON p.i = k.i LEFT JOIN e ON e.id = p.id"
        )
    };
}

// Read kinds (index into the batchers and the read statements).
pub const ARTICLE_SLUG: usize = 0;
pub const ARTICLE_ID: usize = 1;
pub const COMMENTS: usize = 2;
pub const PROFILE: usize = 3;
pub const USER_ID: usize = 4;
pub const USER_EMAIL: usize = 5;
pub const LIST_ALL: usize = 6;
pub const LIST_TAG: usize = 7;
pub const LIST_AUTHOR: usize = 8;
pub const LIST_FAV: usize = 9;
pub const FEED: usize = 10;
pub const TAGS: usize = 11;

const READS: [&str; 12] = [
    // full Article: i, list columns, body
    concat!(
        "WITH r AS MATERIALIZED (SELECT *",
        from_r!(),
        "), e AS MATERIALIZED (",
        enrich!(", a.body"),
        " WHERE a.slug = ANY(ARRAY(SELECT DISTINCT s FROM r)))
 SELECT r.i, ",
        out!("r.v", "r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = e.author_id)"),
        ", e.body FROM r JOIN e ON e.slug = r.s"
    ),
    concat!(
        "WITH r AS MATERIALIZED (SELECT *",
        from_r!(),
        "), e AS MATERIALIZED (",
        enrich!(", a.body"),
        " WHERE a.id = ANY(ARRAY(SELECT DISTINCT n1 FROM r)))
 SELECT r.i, ",
        out!("r.v", "r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = e.author_id)"),
        ", e.body FROM r JOIN e ON e.id = r.n1"
    ),
    // i, article id, then comment columns (NULL when the article has none). Each distinct article's comments
    // are read once; following is per request.
    concat!(
        "WITH r AS MATERIALIZED (SELECT *",
        from_r!(),
        "),
 a AS MATERIALIZED (SELECT a.id, a.slug FROM articles a WHERE a.slug = ANY(ARRAY(SELECT DISTINCT s FROM r))),
 c AS MATERIALIZED (SELECT a.id AS aid, c.*, u.username, u.bio, u.image FROM a
   CROSS JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
     WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
   LEFT JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id) u ON true)
 SELECT r.i, a.id, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image,
 r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = c.author_id)
 FROM r JOIN a ON a.slug = r.s LEFT JOIN c ON c.aid = a.id"
    ),
    concat!(
        "SELECT r.i, u.username, u.bio, u.image,
 r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id)",
        from_r!(),
        " JOIN users u ON u.username = r.s"
    ),
    concat!("SELECT r.i, u.id, u.username, u.email, u.bio, u.image", from_r!(), " JOIN users u ON u.id = r.v"),
    concat!("SELECT r.i, u.id, u.username, u.email, u.bio, u.image, u.password_hash", from_r!(), " JOIN users u ON u.email = r.s"),
    // The global count depends on no request, so it runs once per statement; it walks the primary key from
    // the oldest (frozen, all-visible) end, which is the same min(count, 1000).
    list!(
        "NULL::int8",
        "SELECT 1 FROM articles ORDER BY id",
        "SELECT id FROM articles ORDER BY id DESC",
        "k.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = k.v AND fo.followee_id = e.author_id)"
    ),
    list!(
        "(SELECT t.id FROM tags t WHERE t.name = r.s)",
        "SELECT 1 FROM article_tags at WHERE at.tag_id = k.key",
        "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = k.key ORDER BY at.article_id DESC",
        "k.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = k.v AND fo.followee_id = e.author_id)"
    ),
    list!(
        "(SELECT u.id FROM users u WHERE u.username = r.s)",
        "SELECT 1 FROM articles x WHERE x.author_id = k.key",
        "SELECT x.id FROM articles x WHERE x.author_id = k.key ORDER BY x.id DESC",
        "k.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = k.v AND fo.followee_id = e.author_id)"
    ),
    list!(
        "(SELECT u.id FROM users u WHERE u.username = r.s)",
        "SELECT 1 FROM favorites f WHERE f.user_id = k.key",
        "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = k.key ORDER BY f.article_id DESC",
        "k.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = k.v AND fo.followee_id = e.author_id)"
    ),
    // Every feed author is followed by the viewer in this snapshot, so following is true.
    list!(
        "ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)",
        "SELECT 1 FROM articles x WHERE x.author_id = ANY(k.key)",
        "SELECT y.id FROM unnest(k.key) fe(id) CROSS JOIN LATERAL
   (SELECT x.id FROM articles x WHERE x.author_id = fe.id ORDER BY x.id DESC LIMIT k.n1 + k.n2) y ORDER BY y.id DESC",
        "true"
    ),
    "SELECT name FROM tags ORDER BY name",
];

// Write statements, each one implicit transaction.
pub const W_REGISTER: usize = 0;
pub const W_USER_UPDATE: usize = 1;
pub const W_FOLLOW: usize = 2;
pub const W_UNFOLLOW: usize = 3;
pub const W_FAV: usize = 4;
pub const W_UNFAV: usize = 5;
pub const W_ARTICLE_CREATE: usize = 6;
pub const W_ARTICLE_UPDATE: usize = 7;
pub const W_ARTICLE_DELETE: usize = 8;
pub const W_COMMENT_CREATE: usize = 9;
pub const W_COMMENT_DELETE: usize = 10;

const WRITES: [&str; 11] = [
    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
    "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1 RETURNING id, username, email, bio, image",
    "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
 SELECT username, bio, image FROM t",
    "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))
 SELECT username, bio, image FROM t",
    "WITH t AS (SELECT id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
 SELECT id FROM t",
    "WITH t AS (SELECT id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t))
 SELECT id FROM t",
    // Existing tags are only read; missing ones are inserted, and DO UPDATE returns the id of one a concurrent
    // request inserted after our snapshot. Row layout: the full Article (as ARTICLE_ID) without i.
    "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
 a AS (INSERT INTO articles (id, slug, author_id, title, description, body)
       SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 FROM n
       RETURNING id, slug, title, description, body, created_at, updated_at, author_id),
 e AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])),
 ins AS (INSERT INTO tags (name) SELECT DISTINCT x FROM unnest($5::text[]) x WHERE x NOT IN (SELECT name FROM e)
         ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name),
 tg AS (SELECT id, name FROM e UNION ALL SELECT id, name FROM ins),
 at AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, tg.id FROM a, tg)
 SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT name FROM tg ORDER BY name),
  0::int8, false, u.username, u.bio, u.image,
  EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = $1), a.body
 FROM a JOIN users u ON u.id = a.author_id",
    // -> id, author_id of the article; the update applies only when the viewer ($5) is the author
    "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1)
 SELECT t.id, t.author_id, (SELECT count(*) FROM w) FROM t",
    "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
 SELECT author_id FROM t",
    "WITH t AS (SELECT id FROM articles WHERE slug = $1),
 c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t
       RETURNING id, body, created_at, updated_at, author_id)
 SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
    "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
 SELECT author_id FROM t",
];

pub struct Conn {
    pub c: Client,
    pub st: Vec<Statement>,
    cross: Option<Statement>,
}

pub enum Reply {
    Rows(Vec<Row>),
    Tags(Arc<Vec<u8>>),
    /// The response body built by the cross-kind statement; empty means not found.
    Body(Vec<u8>),
}

type Job = (Q, oneshot::Sender<Result<Reply, ()>>, Instant);

/// Most jobs one statement carries (per kind, and in the cross-kind statement).
const BATCH_MAX: usize = 64;
const CROSS_MAX: usize = 1024;

struct Queue {
    jobs: Vec<VecDeque<Job>>, // waiting reads, per kind
    claimed: Vec<bool>,       // a reader is collecting this kind
}

pub struct Db {
    queue: Mutex<Queue>,
    wake: Notify,
    writes: Vec<Conn>,
    wr: AtomicUsize,
}

static DB: OnceLock<Db> = OnceLock::new();

pub fn db() -> &'static Db {
    DB.get().unwrap()
}

impl Db {
    /// Queues a read for the next free read connection. Nothing is kept once its statement's rows are handed out.
    pub async fn read(&self, kind: usize, q: Q) -> Result<Reply, ()> {
        let (tx, rx) = oneshot::channel();
        self.queue.lock().unwrap().jobs[kind].push_back((q, tx, Instant::now()));
        self.wake.notify_one();
        rx.await.unwrap_or(Err(()))
    }

    pub fn write(&self) -> &Conn {
        &self.writes[self.wr.fetch_add(1, Ordering::Relaxed) % self.writes.len()]
    }
}

async fn connect(url: &str, sqls: &[&str], cross: bool) -> Conn {
    let (c, conn) = tokio_postgres::connect(url, NoTls).await.expect("connect to Postgres");
    tokio::spawn(async move {
        if let Err(e) = conn.await {
            eprintln!("postgres connection: {e}");
        }
    });
    // Session settings only. Generic plans: the batched statements take arrays, and re-planning them per call
    // would cost more than the plan saves. No memoize, so no request is served a row another one's lookup fetched.
    c.batch_execute(
        "SET plan_cache_mode = force_generic_plan; SET jit = off; SET enable_memoize = off;
         SET max_parallel_workers_per_gather = 0",
    )
    .await
    .expect("session settings");
    let mut st = Vec::new();
    for s in sqls {
        st.push(c.prepare(s).await.unwrap_or_else(|e| panic!("prepare {s}: {e}")));
    }
    let cross = if cross {
        let sql = crate::cross::sql();
        Some(c.prepare_typed(&sql, &crate::cross::param_types()).await.unwrap_or_else(|e| panic!("prepare cross: {e}\n{sql}")))
    } else {
        None
    };
    Conn { c, st, cross }
}

pub async fn init(url: &str, n_read: usize, n_write: usize, wait: Duration, cross: bool) {
    let mut writes = Vec::new();
    for _ in 0..n_write {
        writes.push(connect(url, &WRITES, false).await);
    }
    let queue = Mutex::new(Queue { jobs: (0..READS.len()).map(|_| VecDeque::new()).collect(), claimed: vec![false; READS.len()] });
    let _ = DB.set(Db { queue, wake: Notify::new(), writes, wr: AtomicUsize::new(0) });
    for _ in 0..n_read {
        tokio::spawn(reader(connect(url, &READS, cross).await, wait));
    }
}

/// One per read connection, one statement at a time. It claims the kind whose oldest job has waited longest,
/// lets that job age to `wait` so others of its kind can join, then takes them all. The reads in Postgres never
/// exceed the connections, and whatever queues meanwhile goes out batched.
async fn reader(c: Conn, wait: Duration) {
    let db = db();
    loop {
        let (kind, age) = loop {
            {
                let mut q = db.queue.lock().unwrap();
                let k = (0..q.jobs.len()).filter(|&k| !q.claimed[k] && !q.jobs[k].is_empty()).min_by_key(|&k| q.jobs[k][0].2);
                if let Some(k) = k {
                    let age = q.jobs[k][0].2.elapsed();
                    if c.cross.is_some() && crate::cross::is_cross(k) {
                        // this reader collects every cross kind until the oldest job is old enough
                        for x in 0..q.claimed.len() {
                            if crate::cross::is_cross(x) {
                                q.claimed[x] = true;
                            }
                        }
                    } else {
                        q.claimed[k] = true;
                    }
                    break (k, age);
                }
            }
            db.wake.notified().await;
        };
        if age < wait {
            tokio::time::sleep(wait - age).await;
        }
        if c.cross.is_some() && crate::cross::is_cross(kind) {
            let jobs = {
                let mut q = db.queue.lock().unwrap();
                let mut jobs: Vec<(usize, Job)> = Vec::new();
                for x in 0..q.jobs.len() {
                    if crate::cross::is_cross(x) {
                        q.claimed[x] = false;
                        let n = q.jobs[x].len().min(CROSS_MAX - jobs.len());
                        jobs.extend(q.jobs[x].drain(..n).map(|j| (x, j)));
                        if !q.jobs[x].is_empty() {
                            db.wake.notify_one();
                        }
                    }
                }
                db.wake.notify_one(); // another reader may now collect the next window
                jobs
            };
            read_cross(&c, jobs).await;
            continue;
        }
        let jobs = {
            let mut q = db.queue.lock().unwrap();
            q.claimed[kind] = false;
            let n = q.jobs[kind].len().min(BATCH_MAX);
            let jobs: Vec<Job> = q.jobs[kind].drain(..n).collect();
            if !q.jobs[kind].is_empty() {
                db.wake.notify_one();
            }
            jobs
        };
        if kind == TAGS {
            let r = tags(&c).await.map(Arc::new);
            for (_, tx, _) in jobs {
                let _ = tx.send(r.clone().map(Reply::Tags));
            }
            continue;
        }
        let n = jobs.len();
        let (mut v, mut n1, mut n2, mut s) = (Vec::with_capacity(n), Vec::with_capacity(n), Vec::with_capacity(n), Vec::with_capacity(n));
        let mut txs = Vec::with_capacity(n);
        for (q, tx, _) in jobs {
            v.push(q.v);
            n1.push(q.n1);
            n2.push(q.n2);
            s.push(q.s);
            txs.push(tx);
        }
        match c.c.query(&c.st[kind], &[&v, &n1, &n2, &s]).await {
            Ok(rows) => {
                let mut out: Vec<Vec<Row>> = (0..n).map(|_| Vec::new()).collect();
                for r in rows {
                    out[r.get::<_, i64>(0) as usize - 1].push(r);
                }
                for (tx, rows) in txs.into_iter().zip(out) {
                    let _ = tx.send(Ok(Reply::Rows(rows)));
                }
            }
            Err(e) => {
                eprintln!("read {kind}: {e}");
                for tx in txs {
                    let _ = tx.send(Err(()));
                }
            }
        }
    }
}

/// Runs `jobs` (any mix of cross kinds) as the one cross-kind statement and answers each with its body.
async fn read_cross(c: &Conn, jobs: Vec<(usize, Job)>) {
    let qs: Vec<(usize, &Q)> = jobs.iter().map(|(k, j)| (*k, &j.0)).collect();
    let (n, s) = crate::cross::params(&qs);
    let mut params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> = Vec::with_capacity(5 * s.len());
    for k in 0..s.len() {
        for x in 0..4 {
            params.push(&n[4 * k + x]);
        }
        params.push(&s[k]);
    }
    let kinds: Vec<usize> = jobs.iter().map(|(k, _)| *k).collect();
    match c.c.query(c.cross.as_ref().unwrap(), &params).await {
        Ok(rows) => {
            let bodies = crate::cross::assemble(&kinds, &rows);
            for ((_, (_, tx, _)), b) in jobs.into_iter().zip(bodies) {
                let _ = tx.send(Ok(Reply::Body(b)));
            }
        }
        Err(e) => {
            eprintln!("read cross: {e}");
            for (_, (_, tx, _)) in jobs {
                let _ = tx.send(Err(()));
            }
        }
    }
}

/// The {"tags": [...]} body. Every GET /api/tags waiting when it starts shares this one execution.
async fn tags(c: &Conn) -> Result<Vec<u8>, ()> {
    let rows = c.c.query(&c.st[TAGS], &[]).await.map_err(|e| eprintln!("tags: {e}"))?;
    let mut o = Vec::with_capacity(rows.len() * 12 + 16);
    o.extend_from_slice(b"{\"tags\":[");
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            o.push(b',');
        }
        crate::json::str(&mut o, r.get(0));
    }
    o.extend_from_slice(b"]}");
    Ok(o)
}
