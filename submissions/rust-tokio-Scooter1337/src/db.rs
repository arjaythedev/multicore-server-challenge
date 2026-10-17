//! A fixed set of Postgres connections shared by all requests. tokio-postgres pipelines: concurrent queries on one
//! connection go out back to back without waiting for each other's replies, so a few connections keep Postgres busy
//! with fewer backend wake-ups than one-request-per-connection pooling. Each mutation
//! is one statement, so no HTTP handler needs an exclusive connection.
//! Collecting rows drains through ReadyForQuery before any success response is sent.
//!
//! Reads and writes use separate connections. A write's commit waits for its WAL flush, and on a pipelined
//! connection everything queued behind it would wait too; commits queued on one connection would also flush one at
//! a time. Writes therefore have separate connection-owning actors that group concurrent
//! mutations into durable transactions and release their results only after COMMIT.
//! Without the group-commit feature they use ordinary implicit transactions instead.

use std::{
    ops::Deref,
    sync::{
        Arc, RwLock,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};

#[cfg(feature = "group-commit")]
pub use crate::writer::{Client, Error};
#[cfg(not(feature = "group-commit"))]
pub use tokio_postgres::{Client, Error};
use tokio_postgres::{NoTls, Statement, types::Type};

use crate::sql;

pub struct Stmts {
    pub list_all: Statement,
    pub list_tag: Statement,
    pub list_author: Statement,
    pub list_favorited: Statement,
    pub list_feed: Statement,
    pub article_by_slug: Statement,
    pub article_by_id: Statement,
    pub favorite: Statement,
    pub unfavorite: Statement,
    pub article_create: Statement,
    pub article_update: Statement,
    pub article_delete: Statement,
    pub comments_list: Statement,
    pub comment_create: Statement,
    pub comment_delete: Statement,
    pub profile: Statement,
    pub follow: Statement,
    pub unfollow: Statement,
    pub tags: Statement,
    pub user_by_id: Statement,
    pub user_by_email: Statement,
    pub user_insert: Statement,
    pub user_update: Statement,
}

pub struct Conn {
    pub client: Client,
    pub st: Stmts,
    load: AtomicUsize,
    closed: Arc<AtomicBool>,
}

struct Pool(RwLock<Box<[Arc<Conn>]>>);

pub struct Db {
    reads: Arc<Pool>,
    writes: Arc<Pool>,
}

/// A connection picked for one request; counts as load on it until dropped.
pub struct Lease(Arc<Conn>);

impl Deref for Lease {
    type Target = Conn;
    fn deref(&self) -> &Conn {
        &self.0
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.0.load.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Db {
    pub async fn connect(
        url: &str,
        reads: usize,
        writes: usize,
    ) -> Result<Db, tokio_postgres::Error> {
        assert!(
            reads > 0 && writes > 0 && reads + writes <= 95,
            "1..=95 total database connections"
        );
        let mut conns = futures_util::future::try_join_all(
            (0..reads + writes).map(|i| connect_one(url, i >= reads)),
        )
        .await?;
        let writes = conns.split_off(reads);
        let db = Db {
            reads: Arc::new(Pool(RwLock::new(conns.into_iter().map(Arc::new).collect()))),
            writes: Arc::new(Pool(RwLock::new(
                writes.into_iter().map(Arc::new).collect(),
            ))),
        };
        let (reads, writes, url) = (db.reads.clone(), db.writes.clone(), url.to_owned());
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(250));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                for (pool, write) in [(&reads, false), (&writes, true)] {
                    let failed: Vec<_> = pool
                        .0
                        .read()
                        .expect("database pool")
                        .iter()
                        .enumerate()
                        .filter_map(|(i, c)| c.closed.load(Ordering::Acquire).then_some(i))
                        .collect();
                    for i in failed {
                        // Replace the client and its statements together. Existing
                        // leases finish on their original connection; no query is
                        // replayed, including an uncertain commit.
                        if let Ok(Ok(conn)) =
                            tokio::time::timeout(Duration::from_secs(5), connect_one(&url, write))
                                .await
                        {
                            pool.0.write().expect("database pool")[i] = Arc::new(conn);
                        }
                    }
                }
            }
        });
        Ok(db)
    }

    pub fn len(&self) -> (usize, usize) {
        (
            self.reads.0.read().expect("database pool").len(),
            self.writes.0.read().expect("database pool").len(),
        )
    }

    /// A connection for a read-only statement.
    pub fn read(&self) -> Lease {
        least_loaded(&self.reads)
    }

    /// A connection for a statement that writes (and so waits for a commit).
    pub fn write(&self) -> Lease {
        least_loaded(&self.writes)
    }
}

/// The connection with the fewest queries in flight, so nothing queues behind a busy connection while another is
/// idle. The scan starts at a rotating index so ties spread out.
fn least_loaded(pool: &Pool) -> Lease {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    // One short read guard covers the scan, rather than locking every candidate
    // and then locking the winner again. Requests retain only the selected Arc.
    let conns = pool.0.read().expect("database pool");
    let n = conns.len();
    let start = NEXT.fetch_add(1, Ordering::Relaxed) % n;
    let mut best = None;
    let mut best_load = usize::MAX;
    for i in 0..n {
        let index = (start + i) % n;
        let c = &conns[index];
        if c.closed.load(Ordering::Acquire) {
            continue;
        }
        let load = c.load.load(Ordering::Relaxed);
        if load < best_load {
            best = Some(index);
            best_load = load;
            if load == 0 {
                break;
            }
        }
    }
    // During a complete outage requests fail promptly until recovery; they never
    // silently wait for reconnection or replay potentially committed mutations.
    let conn = conns[best.unwrap_or(start)].clone();
    conn.load.fetch_add(1, Ordering::Relaxed);
    Lease(conn)
}

async fn connect_one(url: &str, _write: bool) -> Result<Conn, tokio_postgres::Error> {
    let (client, connection) = tokio_postgres::connect(url, NoTls).await?;
    let closed = Arc::new(AtomicBool::new(false));
    let disconnected = closed.clone();
    tokio::spawn(async move {
        let result = connection.await;
        disconnected.store(true, Ordering::Release);
        if let Err(e) = result {
            eprintln!("[db] connection error: {e}");
        }
    });
    // Session-level settings on our own connections (allowed by rule 2). Every statement is prepared once; a
    // generic plan means Postgres never re-plans them per execution. JIT never pays off for millisecond queries.
    client
        .batch_execute("SET plan_cache_mode = force_generic_plan; SET jit = off")
        .await?;

    let p = |sql: &'static str, types: &'static [Type]| client.prepare_typed(sql, types);
    let st = Stmts {
        list_all: p(sql::LIST_ALL, &[Type::INT8, Type::INT8, Type::INT8]).await?,
        list_tag: p(
            sql::LIST_TAG,
            &[Type::INT8, Type::INT8, Type::INT8, Type::TEXT],
        )
        .await?,
        list_author: p(
            sql::LIST_AUTHOR,
            &[Type::INT8, Type::INT8, Type::INT8, Type::TEXT],
        )
        .await?,
        list_favorited: p(
            sql::LIST_FAVORITED,
            &[Type::INT8, Type::INT8, Type::INT8, Type::TEXT],
        )
        .await?,
        list_feed: p(
            sql::LIST_FEED,
            &[Type::INT8, Type::INT8, Type::INT8, Type::INT8],
        )
        .await?,
        article_by_slug: p(sql::ARTICLE_BY_SLUG, &[Type::INT8, Type::TEXT]).await?,
        article_by_id: p(sql::ARTICLE_BY_ID, &[Type::INT8, Type::INT8]).await?,
        favorite: p(sql::FAVORITE, &[Type::INT8, Type::TEXT]).await?,
        unfavorite: p(sql::UNFAVORITE, &[Type::INT8, Type::TEXT]).await?,
        article_create: p(
            sql::ARTICLE_CREATE,
            &[
                Type::INT8,
                Type::TEXT,
                Type::TEXT,
                Type::TEXT,
                Type::TEXT_ARRAY,
            ],
        )
        .await?,
        article_update: p(
            sql::ARTICLE_UPDATE,
            &[Type::TEXT, Type::TEXT, Type::TEXT, Type::TEXT, Type::INT8],
        )
        .await?,
        article_delete: p(sql::ARTICLE_DELETE, &[Type::TEXT, Type::INT8]).await?,
        comments_list: p(sql::COMMENTS_LIST, &[Type::INT8, Type::TEXT]).await?,
        comment_create: p(sql::COMMENT_CREATE, &[Type::TEXT, Type::INT8, Type::TEXT]).await?,
        comment_delete: p(sql::COMMENT_DELETE, &[Type::INT8, Type::TEXT, Type::INT8]).await?,
        profile: p(sql::PROFILE, &[Type::INT8, Type::TEXT]).await?,
        follow: p(sql::FOLLOW, &[Type::INT8, Type::TEXT]).await?,
        unfollow: p(sql::UNFOLLOW, &[Type::INT8, Type::TEXT]).await?,
        tags: p(sql::TAGS, &[]).await?,
        user_by_id: p(sql::USER_BY_ID, &[Type::INT8]).await?,
        user_by_email: p(sql::USER_BY_EMAIL, &[Type::TEXT]).await?,
        user_insert: p(sql::USER_INSERT, &[Type::TEXT, Type::TEXT, Type::TEXT]).await?,
        user_update: p(
            sql::USER_UPDATE,
            &[
                Type::INT8,
                Type::TEXT,
                Type::TEXT,
                Type::TEXT,
                Type::TEXT,
                Type::TEXT,
            ],
        )
        .await?,
    };
    #[cfg(feature = "group-commit")]
    let client = Client::new(client, _write);
    Ok(Conn {
        client,
        st,
        load: AtomicUsize::new(0),
        closed,
    })
}
