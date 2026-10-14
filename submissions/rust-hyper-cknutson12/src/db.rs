//! A fixed set of Postgres connections shared by all requests. tokio-postgres pipelines: concurrent queries on one
//! connection go out back to back without waiting for each other's replies, so a few connections keep Postgres busy
//! with far fewer backends, round trips and wake-ups than one-request-per-connection pooling. Every endpoint is a
//! single statement (an implicit transaction of its own), so connections never need to be held exclusively.
//!
//! Reads and writes use separate connections. A write's commit waits for its WAL flush, and on a pipelined
//! connection everything queued behind it would wait too; commits queued on one connection would also flush one at
//! a time instead of sharing a flush (group commit) the way commits on different backends do. So writes get their
//! own, larger set of connections where each one usually carries a single statement.

use std::{
    ops::Deref,
    sync::atomic::{AtomicUsize, Ordering},
};

use tokio_postgres::{Client, NoTls, Statement, types::Type};

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
}

pub struct Db {
    reads: Box<[Conn]>,
    writes: Box<[Conn]>,
}

/// A connection picked for one request; counts as load on it until dropped.
pub struct Lease<'a>(&'a Conn);

impl Deref for Lease<'_> {
    type Target = Conn;
    fn deref(&self) -> &Conn {
        self.0
    }
}

impl Drop for Lease<'_> {
    fn drop(&mut self) {
        self.0.load.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Db {
    pub async fn connect(url: &str, reads: usize, writes: usize) -> Result<Db, tokio_postgres::Error> {
        let mut conns = futures_util::future::try_join_all((0..reads + writes).map(|_| connect_one(url))).await?;
        let writes = conns.split_off(reads);
        Ok(Db { reads: conns.into_boxed_slice(), writes: writes.into_boxed_slice() })
    }

    pub fn len(&self) -> (usize, usize) {
        (self.reads.len(), self.writes.len())
    }

    /// A connection for a read-only statement.
    pub fn read(&self) -> Lease<'_> {
        least_loaded(&self.reads)
    }

    /// A connection for a statement that writes (and so waits for a commit).
    pub fn write(&self) -> Lease<'_> {
        least_loaded(&self.writes)
    }
}

/// The connection with the fewest queries in flight, so nothing queues behind a busy connection while another is
/// idle. The scan starts at a rotating index so ties spread out.
fn least_loaded(conns: &[Conn]) -> Lease<'_> {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let n = conns.len();
    let start = NEXT.fetch_add(1, Ordering::Relaxed);
    let mut best = &conns[start % n];
    let mut best_load = best.load.load(Ordering::Relaxed);
    for i in 1..n {
        if best_load == 0 {
            break;
        }
        let c = &conns[(start + i) % n];
        let l = c.load.load(Ordering::Relaxed);
        if l < best_load {
            best = c;
            best_load = l;
        }
    }
    best.load.fetch_add(1, Ordering::Relaxed);
    Lease(best)
}

async fn connect_one(url: &str) -> Result<Conn, tokio_postgres::Error> {
    let (client, connection) = tokio_postgres::connect(url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("[db] connection error: {e}");
        }
    });
    // Session-level settings on our own connections (allowed by rule 2). Every statement is prepared once; a
    // generic plan means Postgres never re-plans them per execution. JIT never pays off for millisecond queries.
    client.batch_execute("SET plan_cache_mode = force_generic_plan; SET jit = off").await?;

    let p = |sql: &'static str, types: &'static [Type]| client.prepare_typed(sql, types);
    let st = Stmts {
        list_all: p(sql::LIST_ALL, &[Type::INT8, Type::INT8, Type::INT8]).await?,
        list_tag: p(sql::LIST_TAG, &[Type::INT8, Type::INT8, Type::INT8, Type::TEXT]).await?,
        list_author: p(sql::LIST_AUTHOR, &[Type::INT8, Type::INT8, Type::INT8, Type::TEXT]).await?,
        list_favorited: p(sql::LIST_FAVORITED, &[Type::INT8, Type::INT8, Type::INT8, Type::TEXT]).await?,
        list_feed: p(sql::LIST_FEED, &[Type::INT8, Type::INT8, Type::INT8]).await?,
        article_by_slug: p(sql::ARTICLE_BY_SLUG, &[Type::INT8, Type::TEXT]).await?,
        article_by_id: p(sql::ARTICLE_BY_ID, &[Type::INT8, Type::INT8]).await?,
        favorite: p(sql::FAVORITE, &[Type::INT8, Type::TEXT]).await?,
        unfavorite: p(sql::UNFAVORITE, &[Type::INT8, Type::TEXT]).await?,
        article_create: p(sql::ARTICLE_CREATE, &[Type::INT8, Type::TEXT, Type::TEXT, Type::TEXT, Type::TEXT_ARRAY]).await?,
        article_update: p(sql::ARTICLE_UPDATE, &[Type::TEXT, Type::TEXT, Type::TEXT, Type::TEXT, Type::INT8]).await?,
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
        user_update: p(sql::USER_UPDATE, &[Type::INT8, Type::TEXT, Type::TEXT, Type::TEXT, Type::TEXT, Type::TEXT]).await?,
    };
    Ok(Conn { client, st, load: AtomicUsize::new(0) })
}
