//! Optional durable group commit. Each actor owns one connection exclusively.
//! Every response waits for COMMIT's ReadyForQuery. A failed statement rolls the
//! batch back and retries requests individually; an uncertain commit is not retried.
use crate::read_batch::{self, Batch, Pack, RowSort};
use crate::sched::{ReadJob, Sched};
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
    /// All read connections behind one queue; statements are this template's (one connection's), identified by
    /// their position in `template` and re-bound to the executing connection's equivalent.
    Shared(Arc<Sched>, Vec<Statement>),
}
pub struct Client(Mode);
impl Client {
    pub fn shared(sched: Arc<Sched>, template: Vec<Statement>) -> Self {
        Self(Mode::Shared(sched, template))
    }
    /// Runs reads from `sched` on this connection until it closes.
    pub fn serve_shared(
        client: tokio_postgres::Client,
        local: Vec<Statement>,
        batches: Vec<Option<Batch>>,
        sched: Arc<Sched>,
        closed: Arc<std::sync::atomic::AtomicBool>,
    ) {
        crate::db::spawn(read_actor(client, local, batches, sched, closed));
    }
    pub fn new(client: tokio_postgres::Client, write: bool, batches: Vec<Option<Batch>>) -> Self {
        if !write && std::env::var("READ_BATCH_SIZE").ok().as_deref() == Some("0") {
            return Self(Mode::Direct(client));
        }
        let (tx, rx) = mpsc::channel(1024);
        crate::db::spawn(actor(client, rx, write, batches));
        Self(Mode::Group(tx, !write))
    }
    pub async fn query(
        &self,
        st: &Statement,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Vec<Row>, Error> {
        match &self.0 {
            Mode::Direct(c) => c.query(st, params).await.map_err(Error::from),
            Mode::Shared(sched, template) => {
                let family = template
                    .iter()
                    .position(|t| read_batch::same(t, st))
                    .ok_or_else(|| Error::Parameter("not a read statement".into()))?;
                let frame = tokio_postgres::Client::encode_group_query(st, params)?;
                let (reply, rx) = oneshot::channel();
                sched.push(family, frame, reply);
                rx.await.map_err(|_| Error::Closed)?
            }
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
    batches: Vec<Option<Batch>>,
) {
    let delay = std::env::var(if write {
        "WRITE_BATCH_US"
    } else {
        "READ_BATCH_US"
    })
    .ok()
    .map(|s| s.parse::<u64>().expect("WRITE_BATCH_US"))
    .unwrap_or(if write { 1000 } else { 0 });
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
        // Under load the preceding flush already collected a batch. At low load,
        // one millisecond gives concurrent writes a chance to share a flush.
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
        if !write {
            finish_reads(&client, jobs, &batches, trace).await;
            continue;
        }
        if jobs.len() == 1 {
            let job = jobs.pop().unwrap();
            let result = execute(&client, &job).await;
            let _ = job.reply.send(result);
            continue;
        }
        let (begin, results, commit) = transaction(&client, &jobs).await;
        if let Err(e) = begin.and(commit) {
            let e = Error::from(e);
            for job in jobs {
                let _ = job.reply.send(Err(e.clone()));
            }
        } else if results.iter().any(Result::is_err) {
            eprintln!(
                "[db] {} grouped writes rolled back for isolated retry",
                jobs.len()
            );
            // Nothing in the failed batch committed. Isolate conflicting requests
            // on retry so one invalid registration cannot reject another write.
            for job in jobs {
                let result = execute(&client, &job).await;
                let _ = job.reply.send(result);
            }
        } else {
            for (job, result) in jobs.into_iter().zip(results) {
                let _ = job.reply.send(result);
            }
        }
    }
}

/// BEGIN, the jobs and COMMIT in one pipeline. Each request is written to the connection on its future's first
/// poll, and every pass polls them in this order, so every statement runs inside the transaction. (`join_all`
/// would not do: over 32 futures it yields part-way through a pass.) A failing statement aborts the
/// transaction, the rest fail, and Postgres turns the COMMIT into a ROLLBACK. Replies still wait for the
/// COMMIT's result.
async fn transaction(
    client: &tokio_postgres::Client,
    jobs: &[Job],
) -> (
    Result<(), tokio_postgres::Error>,
    Vec<Result<Vec<Row>, Error>>,
    Result<(), tokio_postgres::Error>,
) {
    use futures_util::future::{MaybeDone, maybe_done};
    use std::{future::Future, pin::pin, task::Poll};
    let mut begin = pin!(maybe_done(client.batch_execute("BEGIN")));
    let mut writes: Vec<_> = jobs
        .iter()
        .map(|job| Box::pin(maybe_done(execute(client, job))))
        .collect();
    let mut commit = pin!(maybe_done(client.batch_execute("COMMIT")));
    std::future::poll_fn(|cx| {
        let mut done = begin.as_mut().poll(cx).is_ready();
        for w in &mut writes {
            done &= w.as_mut().poll(cx).is_ready();
        }
        done &= commit.as_mut().poll(cx).is_ready();
        if done { Poll::Ready(()) } else { Poll::Pending }
    })
    .await;
    let out = |f: std::pin::Pin<&mut MaybeDone<_>>| f.take_output().expect("polled to completion");
    let results = writes
        .iter_mut()
        .map(|w| w.as_mut().take_output().expect("polled to completion"))
        .collect();
    (out(begin.as_mut()), results, out(commit.as_mut()))
}

async fn finish_reads(
    client: &tokio_postgres::Client,
    jobs: Vec<Job>,
    batches: &[Option<Batch>],
    trace: bool,
) {
    crate::sched::stats::take();
    if jobs.len() == 1 {
        crate::sched::stats::group(15, 1, false);
        let job = jobs.into_iter().next().expect("one job");
        let result = execute(client, &job).await;
        let _ = job.reply.send(result);
        return;
    }
    match grouped_reads(client, &jobs, batches, trace).await {
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
                let result = execute(client, &job).await;
                let _ = job.reply.send(result);
            }
        }
    }
}

async fn grouped_reads(
    client: &tokio_postgres::Client,
    jobs: &[Job],
    batches: &[Option<Batch>],
    trace: bool,
) -> Result<Vec<Vec<Row>>, Error> {
    if batches.iter().all(Option::is_none) {
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
    let mut routes: Vec<(Vec<usize>, bool, bool, RowSort, Pack)> = Vec::new();
    let mut used = vec![false; jobs.len()];
    for i in 0..jobs.len() {
        if used[i] {
            continue;
        }
        let batch = batches
            .iter()
            .flatten()
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
                    .flatten()
                    .position(|b| read_batch::same(&b.original, &jobs[i].statement))
                    .map(|i| i as isize)
                    .unwrap_or(-1),
                group.len()
            );
        }
        let broadcast = batch.is_some_and(|b| b.broadcast);
        let coalesced = group.len() > 1 && !broadcast;
        let family = batches
            .iter()
            .position(|b| {
                b.as_ref()
                    .is_some_and(|b| read_batch::same(&b.original, &jobs[i].statement))
            })
            .unwrap_or(14);
        if !coalesced {
            crate::sched::stats::group(family, group.len(), broadcast);
        }
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
            crate::sched::stats::group(
                family,
                group.len(),
                !std::ptr::eq(statement, &batch.statement),
            );
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
        let sort = batch.map_or(RowSort::Sql, |b| b.sort);
        // The packed shape belongs to the shared statement only.
        let pack = match batch {
            Some(b)
                if coalesced
                    && b.shared
                        .as_ref()
                        .zip(wire.last())
                        .is_some_and(|(s, (st, _))| read_batch::same(s, st)) =>
            {
                b.pack
            }
            _ => Pack::No,
        };
        routes.push((group, coalesced, broadcast, sort, pack));
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
    for ((group, coalesced, broadcast, sort, pack), rows) in routes.into_iter().zip(results) {
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
        let per = read_batch::demux(rows, group.len(), sort, pack)?;
        for (&index, rows) in group.iter().zip(per) {
            out[index] = rows;
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

async fn read_actor(
    client: tokio_postgres::Client,
    local: Vec<Statement>,
    batches: Vec<Option<Batch>>,
    sched: Arc<Sched>,
    closed: Arc<std::sync::atomic::AtomicBool>,
) {
    use std::sync::atomic::Ordering;
    let me = Arc::new(tokio::sync::Notify::new());
    let trace = std::env::var_os("BATCH_TRACE").is_some();
    loop {
        if closed.load(Ordering::Acquire) {
            return;
        }
        let t0 = std::time::Instant::now();
        let jobs = sched.take(&me).await;
        if closed.load(Ordering::Acquire) {
            sched.requeue(jobs);
            return;
        }
        let t1 = std::time::Instant::now();
        crate::sched::stats::take();
        if trace {
            eprintln!(
                "[read-take] family={} requests={}",
                jobs[0].family,
                jobs.len()
            );
        }
        finish_shared(&client, &local, &batches, jobs, trace).await;
        crate::sched::stats::conn_time(t1 - t0, t1.elapsed());
    }
}

async fn finish_shared(
    client: &tokio_postgres::Client,
    local: &[Statement],
    batches: &[Option<Batch>],
    jobs: Vec<ReadJob>,
    trace: bool,
) {
    match run_reads(client, local, batches, &jobs, trace).await {
        Ok(results) => {
            for (job, rows) in jobs.into_iter().zip(results) {
                let _ = job.reply.send(Ok(rows));
            }
        }
        Err(error) => {
            if trace {
                eprintln!("[sql-batch-fallback] {error}");
            }
            // Read-only: the implicit transaction ended at Sync, so individual retries are safe.
            for job in jobs {
                let result = match rebind(&local[job.family], &job.frame) {
                    Ok(frame) => client
                        .query_group_encoded(&[(&local[job.family], frame)])
                        .await
                        .map(|mut r| r.pop().expect("one query"))
                        .map_err(Error::from),
                    Err(e) => Err(e),
                };
                let _ = job.reply.send(result);
            }
        }
    }
}

fn rebind(st: &Statement, frame: &Bytes) -> Result<Bytes, Error> {
    tokio_postgres::Client::rebind_group_query(st, frame)
        .ok_or_else(|| Error::Parameter("invalid read frame".into()))
}

/// One round trip for `jobs` (grouped by family): one execution per coalesced family, else one per request.
async fn run_reads(
    client: &tokio_postgres::Client,
    local: &[Statement],
    batches: &[Option<Batch>],
    jobs: &[ReadJob],
    trace: bool,
) -> Result<Vec<Vec<Row>>, Error> {
    let mut wire: Vec<(Statement, Bytes)> = Vec::new();
    // (first job, job count, kind): 0 = single, 1 = coalesced, 2 = broadcast
    let mut routes: Vec<(usize, usize, u8, RowSort, Pack)> = Vec::new();
    let mut i = 0;
    while i < jobs.len() {
        let family = jobs[i].family;
        let mut n = 1;
        while i + n < jobs.len() && jobs[i + n].family == family {
            n += 1;
        }
        let st = &local[family];
        match &batches[family] {
            Some(batch) if n > 1 && batch.broadcast => {
                crate::sched::stats::group(family, n, true);
                wire.push((st.clone(), rebind(st, &jobs[i].frame)?));
                routes.push((i, n, 2, RowSort::Sql, Pack::No));
            }
            Some(batch) if n > 1 => {
                let frames: Vec<_> = jobs[i..i + n].iter().map(|j| &j.frame).collect();
                let arrays = read_batch::arrays(&frames, st.params())
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
                let shared = !std::ptr::eq(statement, &batch.statement);
                crate::sched::stats::group(family, n, shared);
                if trace && shared {
                    eprintln!("[sql-enrich] family={family} requests={n}");
                }
                let encoded = tokio_postgres::Client::encode_group_query(statement, &refs)?;
                wire.push((statement.clone(), encoded));
                let pack = if shared { batch.pack } else { Pack::No };
                routes.push((i, n, 1, batch.sort, pack));
            }
            _ => {
                crate::sched::stats::group(family, n, false);
                for (j, job) in jobs.iter().enumerate().skip(i).take(n) {
                    wire.push((st.clone(), rebind(st, &job.frame)?));
                    routes.push((j, 1, 0, RowSort::Sql, Pack::No));
                }
            }
        }
        i += n;
    }
    let requests: Vec<_> = wire.iter().map(|(st, bytes)| (st, bytes.clone())).collect();
    let results = client.query_group_encoded(&requests).await?;
    if results.len() != routes.len() {
        return Err(Error::Rows);
    }
    let mut out: Vec<Vec<Row>> = (0..jobs.len()).map(|_| Vec::new()).collect();
    for ((first, n, kind, sort, pack), rows) in routes.into_iter().zip(results) {
        match kind {
            0 => out[first] = rows,
            2 => {
                for slot in &mut out[first + 1..first + n] {
                    *slot = rows.clone();
                }
                out[first] = rows;
            }
            _ => {
                let per = read_batch::demux(rows, n, sort, pack)?;
                for (slot, rows) in out[first..first + n].iter_mut().zip(per) {
                    *slot = rows;
                }
            }
        }
    }
    Ok(out)
}
