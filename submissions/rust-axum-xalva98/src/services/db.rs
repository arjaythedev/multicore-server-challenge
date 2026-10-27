//! Database access. A few shared connections per pool, each carrying many requests' statements at once
//! (tokio-postgres pipelines them), so a Postgres backend works through a queue instead of waking once per
//! query. Every request is one autocommitting statement; only a transaction gets a connection to itself.

use std::collections::HashMap;
use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_postgres::types::{FromSql, ToSql, Type};
use tokio_postgres::{Client, Config, NoTls, Row, Statement};

use crate::error::AppError;

pub type PgError = tokio_postgres::Error;
pub type Params<'a> = &'a [&'a (dyn ToSql + Sync)];

/// A statement and its parameter types. Declared `static`: its address keys the per-connection prepared cache.
pub struct Stmt {
    pub sql: &'static str,
    pub types: &'static [Type],
}

/// A named row struct read by column name, as `sqlx::FromRow` does.
pub trait FromRow: Sized {
    fn from_row(row: &Row) -> Result<Self, PgError>;
}

pub struct Settings {
    pub read_connections: usize,
    pub write_connections: usize,
    pub transaction_connections: usize,
    pub acquire_timeout: Duration,
    pub statement_timeout_ms: u64,
    pub plan_cache_mode: String,
}

/// Reads and writes run on separate connections: a commit waits for its WAL flush, and on a pipelined
/// connection everything queued behind it would wait too.
#[derive(Clone)]
pub struct Db {
    reads: Arc<Shared>,
    writes: Arc<Shared>,
    transactions: Arc<Exclusive>,
}

impl Db {
    /// Opens every connection up front and prepares `statements` on each: no request pays for either.
    pub async fn connect(url: &str, settings: Settings, statements: &[&'static Stmt]) -> Result<Db, PgError> {
        let session = Arc::new(Session {
            config: url.parse::<Config>()?,
            setup: format!(
                "SET statement_timeout = {}; SET plan_cache_mode = {}; SET jit = off",
                settings.statement_timeout_ms,
                setting_word(&settings.plan_cache_mode)
            ),
            acquire_timeout: settings.acquire_timeout,
        });
        Ok(Db {
            reads: Arc::new(Shared::open(session.clone(), settings.read_connections, statements).await?),
            writes: Arc::new(Shared::open(session.clone(), settings.write_connections, statements).await?),
            transactions: Arc::new(Exclusive::open(session, settings.transaction_connections).await?),
        })
    }

    pub fn read(&self) -> &Shared {
        &self.reads
    }

    pub fn write(&self) -> &Shared {
        &self.writes
    }

    /// A connection of its own, for a transaction of several statements.
    pub async fn transaction_connection(&self) -> Result<Leased, AppError> {
        self.transactions.acquire().await
    }
}

fn setting_word(value: &str) -> String {
    value.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_').collect()
}

struct Session {
    config: Config,
    setup: String,
    acquire_timeout: Duration,
}

impl Session {
    async fn open(&self) -> Result<Client, PgError> {
        let (client, connection) = self.config.connect(NoTls).await?;
        tokio::spawn(async move {
            if let Err(e) = connection.await {
                tracing::warn!("postgres connection ended: {e}");
            }
        });
        client.batch_execute(&self.setup).await?;
        Ok(client)
    }
}

struct Live {
    client: Client,
    prepared: Mutex<HashMap<usize, Statement>>,
}

impl Live {
    fn new(client: Client) -> Live {
        Live { client, prepared: Mutex::new(HashMap::new()) }
    }

    async fn statement(&self, stmt: &'static Stmt) -> Result<Statement, PgError> {
        let key = stmt as *const Stmt as usize;
        let cached = self.prepared.lock().unwrap_or_else(PoisonError::into_inner).get(&key).cloned();
        if let Some(statement) = cached {
            return Ok(statement);
        }
        let statement = self.client.prepare_typed(stmt.sql, stmt.types).await?;
        self.prepared.lock().unwrap_or_else(PoisonError::into_inner).insert(key, statement.clone());
        Ok(statement)
    }
}

struct Slot {
    live: RwLock<Arc<Live>>,
    in_flight: AtomicUsize,
    reconnecting: AtomicBool,
}

impl Slot {
    fn live(&self) -> Arc<Live> {
        self.live.read().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

/// Connections shared by every request; a statement goes to the one with the fewest in flight.
pub struct Shared {
    slots: Box<[Arc<Slot>]>,
    session: Arc<Session>,
    next: AtomicUsize,
}

struct InFlight<'a>(&'a Slot);

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.0.in_flight.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Shared {
    async fn open(session: Arc<Session>, size: usize, statements: &[&'static Stmt]) -> Result<Shared, PgError> {
        let mut slots = Vec::with_capacity(size.max(1));
        for _ in 0..size.max(1) {
            let live = Live::new(session.open().await?);
            for stmt in statements {
                live.statement(stmt).await?;
            }
            slots.push(Arc::new(Slot {
                live: RwLock::new(Arc::new(live)),
                in_flight: AtomicUsize::new(0),
                reconnecting: AtomicBool::new(false),
            }));
        }
        Ok(Shared { slots: slots.into_boxed_slice(), session, next: AtomicUsize::new(0) })
    }

    /// The least loaded connection, scanning from a rotating start so ties spread out.
    fn pick(&self) -> &Arc<Slot> {
        let n = self.slots.len();
        let start = self.next.fetch_add(1, Ordering::Relaxed);
        let mut best = &self.slots[start % n];
        let mut best_load = best.in_flight.load(Ordering::Relaxed);
        for i in 1..n {
            if best_load == 0 {
                break;
            }
            let slot = &self.slots[(start + i) % n];
            let load = slot.in_flight.load(Ordering::Relaxed);
            if load < best_load {
                best = slot;
                best_load = load;
            }
        }
        best
    }

    async fn rows(&self, stmt: &'static Stmt, params: Params<'_>, at_most_one: bool) -> Result<Vec<Row>, PgError> {
        let slot = self.pick();
        slot.in_flight.fetch_add(1, Ordering::Relaxed);
        let _in_flight = InFlight(slot);
        let live = slot.live();
        let result = match live.statement(stmt).await {
            Ok(statement) if at_most_one => live.client.query_opt(&statement, params).await.map(|r| r.into_iter().collect()),
            Ok(statement) => live.client.query(&statement, params).await,
            Err(e) => Err(e),
        };
        if result.is_err() && live.client.is_closed() {
            self.replace(slot.clone());
        }
        result
    }

    /// A broken connection is replaced in the background; its statements are prepared again on first use.
    fn replace(&self, slot: Arc<Slot>) {
        if slot.reconnecting.swap(true, Ordering::AcqRel) {
            return;
        }
        let session = self.session.clone();
        tokio::spawn(async move {
            loop {
                match session.open().await {
                    Ok(client) => {
                        *slot.live.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(Live::new(client));
                        break;
                    }
                    Err(e) => {
                        tracing::warn!("postgres reconnect failed: {e}");
                        tokio::time::sleep(Duration::from_millis(500)).await;
                    }
                }
            }
            slot.reconnecting.store(false, Ordering::Release);
        });
    }

    pub async fn all<T: FromRow>(&self, stmt: &'static Stmt, params: Params<'_>) -> Result<Vec<T>, PgError> {
        self.rows(stmt, params, false).await?.iter().map(T::from_row).collect()
    }

    /// At most one row; a statement that returns more is an error.
    pub async fn opt<T: FromRow>(&self, stmt: &'static Stmt, params: Params<'_>) -> Result<Option<T>, PgError> {
        self.rows(stmt, params, true).await?.first().map(T::from_row).transpose()
    }

    /// The first column of the row, if there is one.
    pub async fn scalar<T: for<'a> FromSql<'a>>(&self, stmt: &'static Stmt, params: Params<'_>) -> Result<Option<T>, PgError> {
        self.rows(stmt, params, true).await?.first().map(|row| row.try_get(0)).transpose()
    }
}

/// Connections held by one request at a time, for transactions.
struct Exclusive {
    idle: Mutex<Vec<Client>>,
    permits: Arc<Semaphore>,
    session: Arc<Session>,
}

impl Exclusive {
    async fn open(session: Arc<Session>, size: usize) -> Result<Exclusive, PgError> {
        let mut idle = Vec::with_capacity(size.max(1));
        for _ in 0..size.max(1) {
            idle.push(session.open().await?);
        }
        Ok(Exclusive { permits: Arc::new(Semaphore::new(idle.len())), idle: Mutex::new(idle), session })
    }

    async fn acquire(self: &Arc<Self>) -> Result<Leased, AppError> {
        let permit = tokio::time::timeout(self.session.acquire_timeout, self.permits.clone().acquire_owned())
            .await
            .map_err(|_| AppError::internal_server_error("no transaction connection within the acquire timeout"))?
            .map_err(|e| AppError::internal_server_error(format!("pool closed: {e}")))?;
        let idle = self.idle.lock().unwrap_or_else(PoisonError::into_inner).pop();
        let client = match idle {
            Some(client) if !client.is_closed() => client,
            _ => self.session.open().await.map_err(AppError::db("open a transaction connection"))?,
        };
        Ok(Leased { client, pool: self.clone(), permit })
    }
}

/// An exclusive connection. Dropped without `release` (a cancelled request), it is closed, never reused.
pub struct Leased {
    client: Client,
    pool: Arc<Exclusive>,
    permit: OwnedSemaphorePermit,
}

impl Leased {
    /// Hands the connection back once its transaction ended, unless the connection itself broke.
    pub fn release<T>(self, result: Result<T, PgError>) -> Result<T, PgError> {
        let Leased { client, pool, permit } = self;
        if !client.is_closed() {
            pool.idle.lock().unwrap_or_else(PoisonError::into_inner).push(client);
        }
        drop(permit);
        result
    }
}

impl Deref for Leased {
    type Target = Client;

    fn deref(&self) -> &Client {
        &self.client
    }
}

impl DerefMut for Leased {
    fn deref_mut(&mut self) -> &mut Client {
        &mut self.client
    }
}
