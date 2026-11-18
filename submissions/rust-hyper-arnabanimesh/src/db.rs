//! Postgres access.
//!
//! Every worker thread owns a few connections. A tokio-postgres `Client` pipelines: any number of
//! requests can be in flight on one connection, their messages are coalesced into few socket writes, and
//! Postgres answers them in order. Every statement is a single round trip and is prepared once per
//! connection; every multi-step operation of the reference SQL is folded into one statement (a
//! data-modifying CTE where needed) so that nothing ever needs a multi-statement transaction on a shared,
//! pipelined connection.

use std::ops::Deref;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use tokio_postgres::types::Type as T;
use tokio_postgres::{Client, Config, Error, NoTls, SimpleQueryMessage, Statement};

// ---------------------------------------------------------------------------------------------------
// SQL
// ---------------------------------------------------------------------------------------------------

/// Everything after the first three columns of an article row (`a` = articles row, `u` = its author,
/// `$1` = viewer). Same sub-selects as the reference SQL's ARTICLE_LIST_SELECT.
const TAIL: &str = "a.created_at, a.updated_at, \
ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, \
(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, \
u.username, u.bio, u.image, \
EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following";

/// List statements return the page *and* the capped count (column 12, an uncorrelated sub-select that
/// Postgres evaluates once), so a list request is one round trip. An empty page falls back to the plain
/// count statements below.
fn list_sql(total: &str, source: &str) -> String {
    format!("SELECT a.slug, a.title, a.description, {TAIL}, {total} AS total {source}")
}

fn sql_list_all() -> String {
    // The page is cut out first (index walk + LIMIT/OFFSET) and only then joined and decorated, so the
    // per-row sub-selects never run for rows that are skipped by OFFSET.
    list_sql(
        "(SELECT count(*) FROM (SELECT 1 FROM articles x LIMIT 1000) s)",
        "FROM (SELECT id, slug, author_id, title, description, created_at, updated_at \
         FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3) a \
         JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
    )
}

fn sql_list_tag() -> String {
    list_sql(
        "(SELECT count(*) FROM (SELECT 1 FROM article_tags at2 WHERE at2.tag_id = \
         (SELECT t2.id FROM tags t2 WHERE t2.name = $4) LIMIT 1000) s)",
        "FROM articles a JOIN users u ON u.id = a.author_id \
         WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = \
         (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) \
         ORDER BY a.id DESC",
    )
}

fn sql_list_author() -> String {
    list_sql(
        "(SELECT count(*) FROM (SELECT 1 FROM articles x WHERE x.author_id = \
         (SELECT u2.id FROM users u2 WHERE u2.username = $4) LIMIT 1000) s)",
        "FROM (SELECT id, slug, author_id, title, description, created_at, updated_at \
         FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4) \
         ORDER BY id DESC LIMIT $2 OFFSET $3) a \
         JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
    )
}

fn sql_list_fav() -> String {
    list_sql(
        "(SELECT count(*) FROM (SELECT 1 FROM favorites f2 WHERE f2.user_id = \
         (SELECT fu2.id FROM users fu2 WHERE fu2.username = $4) LIMIT 1000) s)",
        "FROM articles a JOIN users u ON u.id = a.author_id \
         WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = \
         (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) \
         ORDER BY a.id DESC",
    )
}

/// `$2`/`$3` are int4 here (the reference SQL casts them with `::int`).
fn sql_list_feed() -> String {
    list_sql(
        "(SELECT count(*) FROM (SELECT 1 FROM articles a3 WHERE a3.author_id IN \
         (SELECT fo3.followee_id FROM follows fo3 WHERE fo3.follower_id = $1) LIMIT 1000) s)",
        "FROM articles a JOIN users u ON u.id = a.author_id \
         WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL \
         (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC \
         LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) \
         ORDER BY a.id DESC",
    )
}

const SQL_COUNT_ALL: &str = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s";
const SQL_COUNT_TAG: &str = "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = \
    (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s";
const SQL_COUNT_AUTHOR: &str = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = \
    (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s";
const SQL_COUNT_FAV: &str = "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = \
    (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s";
const SQL_COUNT_FEED: &str = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN \
    (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s";

/// One row holding all tag names, sorted. Postgres walks the unique index, so there is no sort.
const SQL_TAGS: &str = "SELECT ARRAY(SELECT name FROM tags ORDER BY name)";

/// ARTICLE_FULL_SELECT; `by` is `a.slug = $2` or `a.id = $2`.
fn sql_article(by: &str) -> String {
    format!(
        "SELECT a.slug, a.title, a.description, a.body, {TAIL} \
         FROM articles a JOIN users u ON u.id = a.author_id WHERE {by}"
    )
}

/// One row per comment (newest 100). An article without comments yields exactly one row whose comment
/// columns are NULL; an unknown slug yields no row (-> 404). So existence + comments = one round trip.
const SQL_COMMENTS: &str = "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, \
    EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following \
    FROM articles a \
    LEFT JOIN LATERAL (SELECT c2.id, c2.body, c2.created_at, c2.updated_at, c2.author_id \
      FROM comments c2 WHERE c2.article_id = a.id ORDER BY c2.created_at DESC, c2.id DESC LIMIT 100) c ON true \
    LEFT JOIN users u ON u.id = c.author_id \
    WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC";

/// 404 check + insert + author join in one statement. No row -> the article does not exist.
const SQL_COMMENT_INSERT: &str = "WITH art AS (SELECT id FROM articles WHERE slug = $2), \
    c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $1, $3 FROM art \
      RETURNING id, body, created_at, updated_at, author_id) \
    SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
    FROM c JOIN users u ON u.id = c.author_id";

/// Deletes only if the comment belongs to the article and the viewer; 0 rows -> look up why.
const SQL_COMMENT_DELETE: &str = "DELETE FROM comments c USING articles a \
    WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3";
const SQL_COMMENT_LOOKUP: &str = "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id \
    WHERE c.id = $1 AND a.slug = $2";

/// Look the article up and (un)favorite it in one statement; the row returned is the article id.
const SQL_FAV_ADD: &str = "WITH art AS (SELECT id FROM articles WHERE slug = $2), \
    ins AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM art ON CONFLICT DO NOTHING) \
    SELECT id FROM art";
const SQL_FAV_DEL: &str = "WITH art AS (SELECT id FROM articles WHERE slug = $2), \
    del AS (DELETE FROM favorites WHERE user_id = $1 AND article_id IN (SELECT id FROM art)) \
    SELECT id FROM art";

/// Look the user up and (un)follow in one statement; the row returned is the profile.
const SQL_FOLLOW_ADD: &str = "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
    ins AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING) \
    SELECT username, bio, image FROM u";
const SQL_FOLLOW_DEL: &str = "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
    del AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u)) \
    SELECT username, bio, image FROM u";

const SQL_PROFILE: &str = "SELECT u.username, u.bio, u.image, \
    EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following \
    FROM users u WHERE u.username = $2";

const SQL_USER_BY_ID: &str = "SELECT id, username, email, bio, image FROM users WHERE id = $1";
const SQL_USER_BY_EMAIL: &str =
    "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1";
const SQL_USER_INSERT: &str = "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) \
    RETURNING id, username, email, bio, image";
const SQL_USER_UPDATE: &str = "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
    password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
    WHERE id = $1 RETURNING id, username, email, bio, image";

/// The reference's four-statement transaction as ONE statement (so it is atomic on a shared, pipelined
/// connection): allocate the id, insert the article, upsert the tags, link them. Tags that already
/// existed are read from the snapshot, tags created by this very statement come back via RETURNING.
const SQL_ARTICLE_INSERT: &str = "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id), \
    a AS (INSERT INTO articles (id, slug, author_id, title, description, body) \
      SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, \
             $1, $2, $3, $4 FROM n RETURNING id), \
    nt AS (INSERT INTO tags (name) SELECT DISTINCT unnest($5::text[]) ON CONFLICT (name) DO NOTHING RETURNING id), \
    lnk AS (INSERT INTO article_tags (article_id, tag_id) \
      SELECT a.id, t.id FROM a CROSS JOIN \
        (SELECT id FROM tags WHERE name = ANY($5::text[]) UNION SELECT id FROM nt) t \
      RETURNING article_id) \
    SELECT id FROM a";

const SQL_ARTICLE_LOOKUP: &str = "SELECT id, author_id FROM articles WHERE slug = $1";
const SQL_ARTICLE_UPDATE: &str = "UPDATE articles SET title = COALESCE($2, title), \
    description = COALESCE($3, description), body = COALESCE($4, body), \
    slug = CASE WHEN $2::text IS NULL THEN slug ELSE \
      trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, \
    updated_at = now() WHERE id = $1";
const SQL_ARTICLE_DELETE: &str = "DELETE FROM articles WHERE id = $1";

/// Session settings for our own connections (rule 2 allows session-level `SET`).
///
/// Always: `jit = off` and no parallel workers, so queries that run in microseconds never pay start-up costs.
///
/// With `generic` (the default, `PG_GENERIC_PLANS=0` turns it off):
///  * `plan_cache_mode = force_generic_plan`: plan every statement once per connection. With `LIMIT`/`OFFSET`
///    as parameters Postgres otherwise keeps choosing custom plans, i.e. re-plans the list statements on every
///    execution, and planning is a large part of their cost.
///  * `enable_hashjoin = off`, `enable_mergejoin = off`: a generic plan cannot see the value of `LIMIT`, so it
///    assumes a page is 10% of the table and could pick a hash join that reads all 100k users. Every join in
///    this app is a primary-key lookup, so nested loops over indexes are always the right plan; forbidding the
///    others makes the generic plans safe.
fn session_setup(generic: bool) -> String {
    let mut s = String::from("SET jit = off; SET max_parallel_workers_per_gather = 0");
    if generic {
        s.push_str(
            "; SET plan_cache_mode = force_generic_plan; SET enable_hashjoin = off; SET enable_mergejoin = off",
        );
    }
    s
}

/// The statements whose generic plans are worth looking at (`conduit --check`).
fn explain_targets() -> Vec<(&'static str, String)> {
    vec![
        ("list_all", sql_list_all()),
        ("list_tag", sql_list_tag()),
        ("list_author", sql_list_author()),
        ("list_fav", sql_list_fav()),
        ("list_feed", sql_list_feed()),
        ("article_by_slug", sql_article("a.slug = $2")),
        ("comments", SQL_COMMENTS.to_string()),
    ]
}

// ---------------------------------------------------------------------------------------------------
// Statements, connections
// ---------------------------------------------------------------------------------------------------

pub struct Stmts {
    pub tags: Statement,
    pub list_all: Statement,
    pub list_tag: Statement,
    pub list_author: Statement,
    pub list_fav: Statement,
    pub list_feed: Statement,
    pub count_all: Statement,
    pub count_tag: Statement,
    pub count_author: Statement,
    pub count_fav: Statement,
    pub count_feed: Statement,
    pub article_by_slug: Statement,
    pub article_by_id: Statement,
    pub comments: Statement,
    pub comment_insert: Statement,
    pub comment_delete: Statement,
    pub comment_lookup: Statement,
    pub fav_add: Statement,
    pub fav_del: Statement,
    pub follow_add: Statement,
    pub follow_del: Statement,
    pub profile: Statement,
    pub user_by_id: Statement,
    pub user_by_email: Statement,
    pub user_insert: Statement,
    pub user_update: Statement,
    pub article_insert: Statement,
    pub article_lookup: Statement,
    pub article_update: Statement,
    pub article_delete: Statement,
}

async fn prepare_all(c: &Client) -> Result<Stmts, Error> {
    Ok(Stmts {
        tags: c.prepare_typed(SQL_TAGS, &[]).await?,
        list_all: c.prepare_typed(&sql_list_all(), &[T::INT8, T::INT8, T::INT8]).await?,
        list_tag: c.prepare_typed(&sql_list_tag(), &[T::INT8, T::INT8, T::INT8, T::TEXT]).await?,
        list_author: c.prepare_typed(&sql_list_author(), &[T::INT8, T::INT8, T::INT8, T::TEXT]).await?,
        list_fav: c.prepare_typed(&sql_list_fav(), &[T::INT8, T::INT8, T::INT8, T::TEXT]).await?,
        list_feed: c.prepare_typed(&sql_list_feed(), &[T::INT8, T::INT4, T::INT4]).await?,
        count_all: c.prepare_typed(SQL_COUNT_ALL, &[]).await?,
        count_tag: c.prepare_typed(SQL_COUNT_TAG, &[T::TEXT]).await?,
        count_author: c.prepare_typed(SQL_COUNT_AUTHOR, &[T::TEXT]).await?,
        count_fav: c.prepare_typed(SQL_COUNT_FAV, &[T::TEXT]).await?,
        count_feed: c.prepare_typed(SQL_COUNT_FEED, &[T::INT8]).await?,
        article_by_slug: c.prepare_typed(&sql_article("a.slug = $2"), &[T::INT8, T::TEXT]).await?,
        article_by_id: c.prepare_typed(&sql_article("a.id = $2"), &[T::INT8, T::INT8]).await?,
        comments: c.prepare_typed(SQL_COMMENTS, &[T::INT8, T::TEXT]).await?,
        comment_insert: c.prepare_typed(SQL_COMMENT_INSERT, &[T::INT8, T::TEXT, T::TEXT]).await?,
        comment_delete: c.prepare_typed(SQL_COMMENT_DELETE, &[T::INT8, T::TEXT, T::INT8]).await?,
        comment_lookup: c.prepare_typed(SQL_COMMENT_LOOKUP, &[T::INT8, T::TEXT]).await?,
        fav_add: c.prepare_typed(SQL_FAV_ADD, &[T::INT8, T::TEXT]).await?,
        fav_del: c.prepare_typed(SQL_FAV_DEL, &[T::INT8, T::TEXT]).await?,
        follow_add: c.prepare_typed(SQL_FOLLOW_ADD, &[T::INT8, T::TEXT]).await?,
        follow_del: c.prepare_typed(SQL_FOLLOW_DEL, &[T::INT8, T::TEXT]).await?,
        profile: c.prepare_typed(SQL_PROFILE, &[T::INT8, T::TEXT]).await?,
        user_by_id: c.prepare_typed(SQL_USER_BY_ID, &[T::INT8]).await?,
        user_by_email: c.prepare_typed(SQL_USER_BY_EMAIL, &[T::TEXT]).await?,
        user_insert: c.prepare_typed(SQL_USER_INSERT, &[T::TEXT, T::TEXT, T::TEXT]).await?,
        user_update: c
            .prepare_typed(SQL_USER_UPDATE, &[T::INT8, T::TEXT, T::TEXT, T::TEXT, T::TEXT, T::TEXT])
            .await?,
        article_insert: c
            .prepare_typed(SQL_ARTICLE_INSERT, &[T::INT8, T::TEXT, T::TEXT, T::TEXT, T::TEXT_ARRAY])
            .await?,
        article_lookup: c.prepare_typed(SQL_ARTICLE_LOOKUP, &[T::TEXT]).await?,
        article_update: c
            .prepare_typed(SQL_ARTICLE_UPDATE, &[T::INT8, T::TEXT, T::TEXT, T::TEXT])
            .await?,
        article_delete: c.prepare_typed(SQL_ARTICLE_DELETE, &[T::INT8]).await?,
    })
}

pub struct Conn {
    pub client: Client,
    pub st: Stmts,
    inflight: AtomicUsize,
}

pub struct Db {
    conns: Vec<Conn>,
    next: AtomicUsize,
}

/// Holds one "in flight" slot on a connection for as long as it lives.
pub struct Guard<'a> {
    c: &'a Conn,
}

impl Deref for Guard<'_> {
    type Target = Conn;
    fn deref(&self) -> &Conn {
        self.c
    }
}

impl Drop for Guard<'_> {
    fn drop(&mut self) {
        self.c.inflight.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Db {
    /// Opens `n` connections (retrying until Postgres is reachable) and prepares all statements on each.
    pub async fn connect(cfg: &Config, n: usize, generic: bool) -> Db {
        let mut conns = Vec::with_capacity(n);
        for _ in 0..n.max(1) {
            conns.push(connect_one(cfg, generic).await);
        }
        Db { conns, next: AtomicUsize::new(0) }
    }

    /// The connection with the fewest requests in flight (ties broken round-robin).
    pub fn get(&self) -> Guard<'_> {
        let n = self.conns.len();
        let start = self.next.fetch_add(1, Ordering::Relaxed);
        let mut best = start % n;
        let mut best_load = usize::MAX;
        for k in 0..n {
            let i = (start + k) % n;
            let c = &self.conns[i];
            if c.client.is_closed() {
                continue;
            }
            let load = c.inflight.load(Ordering::Relaxed);
            if load < best_load {
                best = i;
                best_load = load;
                if load == 0 {
                    break;
                }
            }
        }
        let c = &self.conns[best];
        c.inflight.fetch_add(1, Ordering::Relaxed);
        Guard { c }
    }
}

async fn connect_one(cfg: &Config, generic: bool) -> Conn {
    let setup = session_setup(generic);
    loop {
        match cfg.connect(NoTls).await {
            Ok((client, connection)) => {
                tokio::spawn(async move {
                    if let Err(e) = connection.await {
                        eprintln!("postgres connection error: {e}");
                    }
                });
                let prepared: Result<Stmts, Error> = match client.batch_execute(&setup).await {
                    Ok(()) => prepare_all(&client).await,
                    Err(e) => Err(e),
                };
                match prepared {
                    Ok(st) => return Conn { client, st, inflight: AtomicUsize::new(0) },
                    Err(e) => eprintln!("postgres setup failed: {e}"),
                }
            }
            Err(e) => eprintln!("postgres connect failed: {e}"),
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// `conduit --check`: connect, apply the session settings, prepare every statement (this validates all
/// SQL against the real schema) and print the generic plans of the heavy statements.
pub async fn check(cfg: &Config, generic: bool) -> Result<(), Error> {
    let (client, connection) = cfg.connect(NoTls).await?;
    tokio::spawn(async move {
        let _ = connection.await;
    });
    client.batch_execute(&session_setup(generic)).await?;
    let _stmts = prepare_all(&client).await?;
    println!("all statements prepared OK (generic plans: {generic})");

    for (name, sql) in explain_targets() {
        let messages = client.simple_query(&format!("EXPLAIN (GENERIC_PLAN) {sql}")).await?;
        let mut plan = String::new();
        for m in messages {
            if let SimpleQueryMessage::Row(row) = m {
                if let Some(line) = row.get(0) {
                    plan.push_str(line);
                    plan.push('\n');
                }
            }
        }
        println!("\n== {name}\n{plan}");
        if plan.contains("Hash Join") || plan.contains("Merge Join") || plan.contains("Seq Scan on users") {
            println!("!! {name}: plan contains a hash/merge join or a seq scan on users");
        }
    }
    Ok(())
}