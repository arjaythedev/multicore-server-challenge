//! Optional durable group commit. Each actor owns one connection exclusively.
//! Every response waits for COMMIT's ReadyForQuery. A failed statement rolls the
//! batch back and retries requests individually; an uncertain commit is not retried.
use crate::read_batch::{self, Batch};
use bytes::{Bytes, BytesMut};
use postgres_types::{Format, IsNull, ToSql, Type};
use std::{fmt, sync::Arc, time::Duration};
use tokio::sync::{mpsc, oneshot};
use tokio_postgres::{Row, Statement, error::SqlState};

#[derive(Debug, Clone)]
pub enum Error {
    Sql(Arc<tokio_postgres::Error>),
    Closed,
    Rows,
    Parameter(String),
}
impl From<tokio_postgres::Error> for Error {
    fn from(e: tokio_postgres::Error) -> Self {
        Self::Sql(Arc::new(e))
    }
}
impl Error {
    pub fn code(&self) -> Option<&SqlState> {
        if let Self::Sql(e) = self {
            e.code()
        } else {
            None
        }
    }
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sql(e) => e.fmt(f),
            Self::Closed => f.write_str("write dispatcher closed"),
            Self::Rows => f.write_str("unexpected row count"),
            Self::Parameter(e) => f.write_str(e),
        }
    }
}
impl std::error::Error for Error {}

#[derive(Debug)]
struct Param {
    bytes: Option<Bytes>,
    format: Format,
}
impl ToSql for Param {
    fn to_sql(
        &self,
        _: &Type,
        out: &mut BytesMut,
    ) -> Result<IsNull, Box<dyn std::error::Error + Send + Sync>> {
        match &self.bytes {
            Some(b) => {
                out.extend_from_slice(b);
                Ok(IsNull::No)
            }
            None => Ok(IsNull::Yes),
        }
    }
    fn accepts(_: &Type) -> bool {
        true
    }
    fn encode_format(&self, _: &Type) -> Format {
        self.format
    }
    postgres_types::to_sql_checked!();
}
struct Job {
    statement: Statement,
    params: Vec<Param>,
    encoded: Option<Bytes>,
    reply: oneshot::Sender<Result<Vec<Row>, Error>>,
}
enum Mode {
    Direct(tokio_postgres::Client),
    Group(mpsc::Sender<Job>, bool),
}
pub struct Client(Mode);
impl Client {
    pub fn new(client: tokio_postgres::Client, write: bool, batches: Vec<Batch>) -> Self {
        if !write && std::env::var("READ_BATCH_SIZE").ok().as_deref() == Some("0") {
            return Self(Mode::Direct(client));
        }
        let (tx, rx) = mpsc::channel(1024);
        tokio::spawn(actor(client, rx, write, batches));
        Self(Mode::Group(tx, !write))
    }
    pub async fn query(
        &self,
        st: &Statement,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Vec<Row>, Error> {
        match &self.0 {
            Mode::Direct(c) => c.query(st, params).await.map_err(Error::from),
            Mode::Group(tx, read) => {
                if params.len() != st.params().len() {
                    return Err(Error::Parameter("parameter count".into()));
                }
                let mut owned = Vec::new();
                let encoded = if *read {
                    Some(tokio_postgres::Client::encode_group_query(st, params)?)
                } else {
                    owned.reserve(params.len());
                    for (p, ty) in params.iter().zip(st.params()) {
                        let mut bytes = BytesMut::new();
                        let null = p
                            .to_sql_checked(ty, &mut bytes)
                            .map_err(|e| Error::Parameter(e.to_string()))?;
                        owned.push(Param {
                            bytes: if matches!(null, IsNull::Yes) {
                                None
                            } else {
                                Some(bytes.freeze())
                            },
                            format: p.encode_format(ty),
                        });
                    }
                    None
                };
                let (reply, rx) = oneshot::channel();
                tx.send(Job {
                    statement: st.clone(),
                    params: owned,
                    encoded,
                    reply,
                })
                .await
                .map_err(|_| Error::Closed)?;
                rx.await.map_err(|_| Error::Closed)?
            }
        }
    }
    pub async fn query_opt(
        &self,
        st: &Statement,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Option<Row>, Error> {
        if let Mode::Direct(c) = &self.0 {
            return c.query_opt(st, params).await.map_err(Error::from);
        }
        let mut rows = self.query(st, params).await?;
        if rows.len() > 1 {
            Err(Error::Rows)
        } else {
            Ok(rows.pop())
        }
    }
    pub async fn query_one(
        &self,
        st: &Statement,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Row, Error> {
        if let Mode::Direct(c) = &self.0 {
            return c.query_one(st, params).await.map_err(Error::from);
        }
        self.query_opt(st, params).await?.ok_or(Error::Rows)
    }
}
async fn execute(client: &tokio_postgres::Client, job: &Job) -> Result<Vec<Row>, Error> {
    if let Some(encoded) = &job.encoded {
        return client
            .query_group_encoded(&[(&job.statement, encoded.clone())])
            .await
            .map(|mut results| results.pop().expect("one query"))
            .map_err(Error::from);
    }
    client
        .query_raw(&job.statement, job.params.iter())
        .await?
        .try_collect()
        .await
        .map_err(Error::from)
}
use futures_util::TryStreamExt;
async fn actor(
    client: tokio_postgres::Client,
    mut rx: mpsc::Receiver<Job>,
    write: bool,
    batches: Vec<Batch>,
) {
    let delay = std::env::var(if write {
        "WRITE_BATCH_US"
    } else {
        "READ_BATCH_US"
    })
    .ok()
    .map(|s| s.parse::<u64>().expect("WRITE_BATCH_US"))
    .unwrap_or(if write { 1000 } else { 300 });
    let batch_limit = if write {
        128
    } else {
        std::env::var("READ_BATCH_SIZE")
            .ok()
            .map(|s| s.parse().expect("READ_BATCH_SIZE"))
            .unwrap_or(32)
    };
    let trace = std::env::var_os("BATCH_TRACE").is_some();
    while let Some(first) = rx.recv().await {
        let mut jobs = Vec::with_capacity(32);
        jobs.push(first);
        // Under load the preceding flush already collected a batch. At low load, a short wait
        // lets concurrent requests share a flush (1 ms for writes, 300 us for reads).
        if delay > 0 && rx.is_empty() {
            tokio::time::sleep(Duration::from_micros(delay)).await;
        }
        while jobs.len() < batch_limit {
            match rx.try_recv() {
                Ok(job) => jobs.push(job),
                Err(_) => break,
            }
        }
        if trace && !write {
            eprintln!("[read-drain] requests={}", jobs.len());
        }
        if jobs.len() == 1 {
            let job = jobs.pop().unwrap();
            let result = execute(&client, &job).await;
            let _ = job.reply.send(result);
            continue;
        }
        if !write {
            let results = grouped_reads(&client, &jobs, &batches, trace).await;
            match results {
                Ok(results) => {
                    for (job, rows) in jobs.into_iter().zip(results) {
                        let _ = job.reply.send(Ok(rows));
                    }
                }
                Err(error) => {
                    if trace {
                        eprintln!("[sql-batch-fallback] {error}");
                    }
                    // The implicit transaction ended at Sync. Only read-only
                    // jobs enter this branch, so individual retries are safe.
                    for job in jobs {
                        let result = execute(&client, &job).await;
                        let _ = job.reply.send(result);
                    }
                }
            }
            continue;
        }
        if let Err(e) = client.batch_execute("BEGIN").await {
            let e = Error::from(e);
            for job in jobs {
                let _ = job.reply.send(Err(e.clone()));
            }
            continue;
        }
        let results =
            futures_util::future::join_all(jobs.iter().map(|job| execute(&client, job))).await;
        if results.iter().any(Result::is_err) {
            eprintln!(
                "[db] rolling back {} grouped writes for isolated retry",
                jobs.len()
            );
            if let Err(e) = client.batch_execute("ROLLBACK").await {
                let e = Error::from(e);
                for job in jobs {
                    let _ = job.reply.send(Err(e.clone()));
                }
                continue;
            }
            // Nothing in the failed batch committed. Isolate conflicting requests
            // on retry so one invalid registration cannot reject another write.
            for job in jobs {
                let result = execute(&client, &job).await;
                let _ = job.reply.send(result);
            }
        } else {
            match client.batch_execute("COMMIT").await {
                Ok(()) => {
                    for (job, result) in jobs.into_iter().zip(results) {
                        let _ = job.reply.send(result);
                    }
                }
                Err(e) => {
                    let e = Error::from(e);
                    for job in jobs {
                        let _ = job.reply.send(Err(e.clone()));
                    }
                }
            }
        }
    }
}

async fn grouped_reads(
    client: &tokio_postgres::Client,
    jobs: &[Job],
    batches: &[Batch],
    trace: bool,
) -> Result<Vec<Vec<Row>>, Error> {
    if batches.is_empty() {
        let requests: Vec<_> = jobs
            .iter()
            .map(|job| {
                (
                    &job.statement,
                    job.encoded.as_ref().expect("read frame").clone(),
                )
            })
            .collect();
        return client
            .query_group_encoded(&requests)
            .await
            .map_err(Error::from);
    }
    let mut wire = Vec::with_capacity(jobs.len());
    let mut routes: Vec<(Vec<usize>, bool, bool)> = Vec::new();
    let mut used = vec![false; jobs.len()];
    for i in 0..jobs.len() {
        if used[i] {
            continue;
        }
        let batch = batches
            .iter()
            .find(|b| read_batch::same(&b.original, &jobs[i].statement));
        let mut group = vec![i];
        if batch.is_some() {
            for j in i + 1..jobs.len() {
                if !used[j] && read_batch::same(&jobs[i].statement, &jobs[j].statement) {
                    group.push(j);
                }
            }
        }
        for &j in &group {
            used[j] = true;
        }
        if trace {
            eprintln!(
                "[read-group] family={} requests={}",
                batches
                    .iter()
                    .position(|b| read_batch::same(&b.original, &jobs[i].statement))
                    .map(|i| i as isize)
                    .unwrap_or(-1),
                group.len()
            );
        }
        let broadcast = batch.is_some_and(|b| b.broadcast);
        let coalesced = group.len() > 1 && !broadcast;
        if trace && broadcast && group.len() > 1 {
            eprintln!("[sql-broadcast] requests={}", group.len());
        }
        if coalesced {
            let batch = batch.expect("eligible statement");
            let frames: Vec<_> = group
                .iter()
                .map(|&j| jobs[j].encoded.as_ref().expect("read frame"))
                .collect();
            let arrays = read_batch::arrays(&frames, batch.original.params())
                .ok_or_else(|| Error::Parameter("invalid binary Bind frame".into()))?;
            let params: Vec<_> = arrays
                .into_iter()
                .map(|bytes| Param {
                    bytes: Some(bytes),
                    format: Format::Binary,
                })
                .collect();
            let refs: Vec<_> = params.iter().map(|p| p as &(dyn ToSql + Sync)).collect();
            let statement = read_batch::statement(batch, &frames);
            if trace && !std::ptr::eq(statement, &batch.statement) {
                eprintln!("[sql-enrich] requests={}", group.len());
            }
            let encoded = tokio_postgres::Client::encode_group_query(statement, &refs)?;
            wire.push((statement.clone(), encoded));
        } else {
            wire.push((
                jobs[i].statement.clone(),
                jobs[i].encoded.as_ref().expect("read frame").clone(),
            ));
        }
        routes.push((group, coalesced, broadcast));
    }
    if trace && wire.len() < jobs.len() {
        eprintln!("[sql-batch] jobs={} executions={}", jobs.len(), wire.len());
    }
    let requests: Vec<_> = wire.iter().map(|(st, bytes)| (st, bytes.clone())).collect();
    let results = client.query_group_encoded(&requests).await?;
    if results.len() != routes.len() {
        return Err(Error::Rows);
    }
    let mut out: Vec<Vec<Row>> = (0..jobs.len()).map(|_| Vec::new()).collect();
    for ((group, coalesced, broadcast), rows) in routes.into_iter().zip(results) {
        if broadcast {
            let (last, others) = group.split_last().ok_or(Error::Rows)?;
            for &index in others {
                out[index] = rows.clone();
            }
            out[*last] = rows;
            continue;
        }
        if !coalesced {
            out[group[0]] = rows;
            continue;
        }
        for row in rows {
            let id: i64 = row.try_get(row.len() - 1)?;
            let pos = usize::try_from(id)
                .ok()
                .and_then(|i| i.checked_sub(1))
                .filter(|&i| i < group.len())
                .ok_or(Error::Rows)?;
            out[group[pos]].push(row);
        }
    }
    if trace && wire.len() < jobs.len() {
        eprintln!(
            "[sql-batch-ok] jobs={} executions={}",
            jobs.len(),
            wire.len()
        );
    }
    Ok(out)
}
