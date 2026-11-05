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
    future::Future,
    ops::Deref,
    sync::{
        Arc, OnceLock, RwLock,
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

/// The runtime that owns every Postgres socket: connection drivers and the read/write actors. On the request
/// workers, a finished round trip waited behind HTTP tasks before its connection sent the next query, which left
/// backends idle for ~40% of each round trip under load. Here it is handled as soon as it arrives.
static DB_RUNTIME: OnceLock<tokio::runtime::Handle> = OnceLock::new();

/// Starts the database runtime with `threads` workers (0 = run database I/O on the request workers).
pub fn start_runtime(threads: usize) {
    if threads == 0 {
        return;
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(threads)
        .thread_name("db")
        .enable_all()
        .build()
        .expect("database runtime");
    assert!(DB_RUNTIME.set(rt.handle().clone()).is_ok());
    std::thread::Builder::new()
        .name("db-runtime".into())
        .spawn(move || rt.block_on(std::future::pending::<()>()))
        .expect("database runtime thread");
}

/// Spawns database I/O on the database runtime. Sockets register with the runtime they are created on, so
/// connections are opened from tasks spawned here too.
pub fn spawn<F>(future: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    match DB_RUNTIME.get() {
        Some(rt) => rt.spawn(future),
        None => tokio::spawn(future),
    }
}

#[derive(Clone)]
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

impl Stmts {
    /// The read statements, in `ReadKind` order.
    pub fn reads(&self) -> [&Statement; ReadKind::COUNT] {
        [
            &self.list_all,
            &self.list_tag,
            &self.list_author,
            &self.list_favorited,
            &self.list_feed,
            &self.article_by_slug,
            &self.article_by_id,
            &self.profile,
            &self.user_by_id,
            &self.user_by_email,
            &self.comments_list,
            &self.tags,
        ]
    }
}

pub struct Conn {
    pub client: Client,
    pub st: Stmts,
    load: AtomicUsize,
    families: [AtomicUsize; ReadKind::COUNT],
    closed: Arc<AtomicBool>,
}

struct Pool(RwLock<Box<[Arc<Conn>]>>);

/// Routing metadata only; it never contains request arguments or database data.
#[derive(Clone, Copy)]
#[repr(usize)]
pub enum ReadKind {
    All,
    Tag,
    Author,
    Favorited,
    Feed,
    ArticleSlug,
    ArticleId,
    Profile,
    UserId,
    UserEmail,
    Comments,
    Tags,
}
impl ReadKind {
    pub const COUNT: usize = 12;
}

pub struct Db {
    /// With the shared read queue: every read goes through this one handle (see sched.rs).
    reader: Option<Arc<Conn>>,
    route_slack: Option<usize>,
    route_tags: bool,
    reads: Arc<Pool>,
    writes: Arc<Pool>,
}

/// A connection picked for one request; counts as load on it until dropped.
pub struct Lease {
    conn: Arc<Conn>,
    family: Option<ReadKind>,
}

impl Deref for Lease {
    type Target = Conn;
    fn deref(&self) -> &Conn {
        &self.conn
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        if let Some(family) = self.family {
            self.conn.families[family as usize].fetch_sub(1, Ordering::Relaxed);
        }
        self.conn.load.fetch_sub(1, Ordering::Relaxed);
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
        let sched = shared_reads().map(|(cap, mixed)| {
            let feed = std::env::var("READ_FEED_CAP")
                .ok()
                .map(|s| s.parse().expect("READ_FEED_CAP"))
                .unwrap_or(cap);
            Arc::new(
                crate::sched::Sched::new(ReadKind::COUNT, cap, mixed)
                    .with_cap(ReadKind::Feed as usize, feed),
            )
        });
        let mut conns = futures_util::future::try_join_all((0..reads + writes).map(|i| {
            let (url, sched) = (url.to_owned(), sched.clone());
            async move {
                spawn(async move { connect_one(&url, i >= reads, sched).await })
                    .await
                    .expect("connect task")
            }
        }))
        .await?;
        let writes = conns.split_off(reads);
        let reader = sched.clone().map(|sched| {
            let st = conns[0].st.clone();
            Arc::new(Conn {
                client: shared_client(sched, &st),
                st,
                load: AtomicUsize::new(0),
                families: std::array::from_fn(|_| AtomicUsize::new(0)),
                closed: Arc::new(AtomicBool::new(false)),
            })
        });
        let route_slack = if cfg!(feature = "group-commit")
            && std::env::var("READ_BATCH_SIZE").ok().as_deref() != Some("0")
            && std::env::var("READ_SQL_BATCH").ok().as_deref() != Some("0")
        {
            match std::env::var("READ_ROUTE_SLACK").ok().as_deref() {
                Some("off") => None,
                Some(value) => Some(value.parse::<usize>().expect("READ_ROUTE_SLACK").min(64)),
                None => Some(8),
            }
        } else {
            None
        };
        let db = Db {
            reader,
            route_slack,
            route_tags: std::env::var("READ_TAG_ROUTE").ok().as_deref() == Some("1"),
            reads: Arc::new(Pool(RwLock::new(conns.into_iter().map(Arc::new).collect()))),
            writes: Arc::new(Pool(RwLock::new(
                writes.into_iter().map(Arc::new).collect(),
            ))),
        };
        let (reads, writes, url) = (db.reads.clone(), db.writes.clone(), url.to_owned());
        let sched_for_reconnect = sched;
        spawn(async move {
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
                        if let Ok(Ok(conn)) = tokio::time::timeout(
                            Duration::from_secs(5),
                            connect_one(&url, write, sched_for_reconnect.clone()),
                        )
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
    pub fn read(&self, family: ReadKind) -> Lease {
        if let Some(reader) = &self.reader {
            reader.load.fetch_add(1, Ordering::Relaxed);
            return Lease {
                conn: reader.clone(),
                family: None,
            };
        }
        // Comments have no combined query. Tag fanout routing is optional.
        if matches!(family, ReadKind::Comments)
            || matches!(family, ReadKind::Tags) && !self.route_tags
        {
            return least_loaded(&self.reads);
        }
        match self.route_slack {
            Some(slack) => compatible(&self.reads, family, slack),
            None => least_loaded(&self.reads),
        }
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
    Lease { conn, family: None }
}

/// Prefer useful batch membership only within a bounded distance of the least
/// loaded healthy connection. No timer, request data or result cache is involved.
fn compatible(pool: &Pool, family: ReadKind, slack: usize) -> Lease {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let conns = pool.0.read().expect("database pool");
    let n = conns.len();
    let start = NEXT.fetch_add(1, Ordering::Relaxed) % n;
    let mut least = None;
    let mut minimum = usize::MAX;
    for i in 0..n {
        let index = (start + i) % n;
        let c = &conns[index];
        if !c.closed.load(Ordering::Acquire) {
            let load = c.load.load(Ordering::Relaxed);
            if load < minimum {
                minimum = load;
                least = Some(index);
            }
        }
    }
    let mut selected = least.unwrap_or(start);
    let mut best_load = minimum;
    let mut best_matches = 0;
    for i in 0..n {
        let index = (start + i) % n;
        let c = &conns[index];
        if c.closed.load(Ordering::Acquire) {
            continue;
        }
        let load = c.load.load(Ordering::Relaxed);
        let matches = c.families[family as usize].load(Ordering::Relaxed);
        if prefer(load, matches, minimum, slack, best_load, best_matches) {
            selected = index;
            best_load = load;
            best_matches = matches;
        }
    }
    let conn = conns[selected].clone();
    conn.load.fetch_add(1, Ordering::Relaxed);
    conn.families[family as usize].fetch_add(1, Ordering::Relaxed);
    Lease {
        conn,
        family: Some(family),
    }
}

#[inline]
fn prefer(
    load: usize,
    matches: usize,
    minimum: usize,
    slack: usize,
    best_load: usize,
    best_matches: usize,
) -> bool {
    load <= minimum.saturating_add(slack)
        && (matches > best_matches || matches == best_matches && load < best_load)
}

/// The shared read queue (default on with group commit): Some((batch cap, mixed families)).
fn shared_reads() -> Option<(usize, bool)> {
    if !cfg!(feature = "group-commit")
        || std::env::var("READ_SCHED").ok().as_deref() == Some("0")
        || std::env::var("READ_BATCH_SIZE").ok().as_deref() == Some("0")
    {
        return None;
    }
    let cap = std::env::var("READ_BATCH_SIZE")
        .ok()
        .map(|s| s.parse().expect("READ_BATCH_SIZE"))
        .unwrap_or(512);
    Some((
        cap,
        std::env::var("READ_SCHED_MODE").ok().as_deref() == Some("mixed"),
    ))
}

#[cfg(feature = "group-commit")]
fn shared_client(sched: Arc<crate::sched::Sched>, st: &Stmts) -> Client {
    Client::shared(sched, st.reads().into_iter().cloned().collect())
}
#[cfg(not(feature = "group-commit"))]
fn shared_client(_: Arc<crate::sched::Sched>, _: &Stmts) -> Client {
    unreachable!("the shared read queue needs group commit")
}

async fn connect_one(
    url: &str,
    _write: bool,
    sched: Option<Arc<crate::sched::Sched>>,
) -> Result<Conn, tokio_postgres::Error> {
    let (client, connection) = tokio_postgres::connect(url, NoTls).await?;
    let closed = Arc::new(AtomicBool::new(false));
    let disconnected = closed.clone();
    spawn(async move {
        let result = connection.await;
        disconnected.store(true, Ordering::Release);
        if let Err(e) = result {
            eprintln!("[db] connection error: {e}");
        }
    });
    // Session-level settings on our own connections (allowed by rule 2). Every statement is prepared once; a
    // generic plan means Postgres never re-plans them per execution. JIT never pays off for millisecond queries, and
    // neither do parallel workers (the box config allows 4 per gather); `PG_PARALLEL=1` keeps the server default.
    client
        .batch_execute(if std::env::var("PG_PARALLEL").ok().as_deref() == Some("1") {
            "SET plan_cache_mode = force_generic_plan; SET jit = off"
        } else {
            "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0"
        })
        .await?;
    // `PG_SET` adds session settings for experiments, e.g. "SET enable_memoize = off".
    if let Ok(extra) = std::env::var("PG_SET") {
        client.batch_execute(&extra).await?;
    }

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
        comments_list: p(
            if std::env::var("READ_COMMENT_SET").ok().as_deref() == Some("1") {
                sql::COMMENTS_LIST_SET
            } else {
                sql::COMMENTS_LIST
            },
            &[Type::INT8, Type::TEXT],
        )
        .await?,
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
    let batches = if !_write
        && std::env::var("READ_SQL_BATCH").ok().as_deref() != Some("0")
        && std::env::var("READ_BATCH_SIZE").ok().as_deref() != Some("0")
    {
        crate::read_batch::prepare(&client, &st).await?
    } else {
        Vec::new()
    };
    #[cfg(feature = "group-commit")]
    let client = match sched {
        Some(sched) if !_write => {
            Client::serve_shared(
                client,
                st.reads().into_iter().cloned().collect(),
                batches,
                sched.clone(),
                closed.clone(),
            );
            shared_client(sched, &st)
        }
        _ => Client::new(client, _write, batches),
    };
    Ok(Conn {
        client,
        st,
        load: AtomicUsize::new(0),
        families: std::array::from_fn(|_| AtomicUsize::new(0)),
        closed,
    })
}

#[cfg(test)]
mod routing_tests {
    use super::prefer;

    #[test]
    fn affinity_has_a_load_bound() {
        assert!(prefer(2, 2, 0, 2, 0, 0));
        assert!(!prefer(3, 3, 0, 2, 0, 0));
        assert!(!prefer(1, 1, 0, 0, 0, 0));
        assert!(prefer(10, 4, 8, 2, 8, 3));
        assert!(!prefer(11, 9, 8, 2, 8, 3));
    }

    #[test]
    fn equal_affinity_uses_less_load_and_preserves_rotating_ties() {
        assert!(prefer(3, 2, 2, 2, 4, 2));
        assert!(!prefer(4, 2, 2, 2, 3, 2));
        assert!(!prefer(3, 2, 2, 2, 3, 2));
        assert!(!prefer(3, 1, 2, 2, 4, 2));
    }
}
