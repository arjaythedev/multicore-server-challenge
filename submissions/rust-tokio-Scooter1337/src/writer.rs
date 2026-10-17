//! Optional durable group commit. Each actor owns one connection exclusively.
//! Every response waits for COMMIT's ReadyForQuery. A failed statement rolls the
//! batch back and retries requests individually; an uncertain commit is not retried.
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
    reply: oneshot::Sender<Result<Vec<Row>, Error>>,
}
enum Mode {
    Direct(tokio_postgres::Client),
    Group(mpsc::Sender<Job>),
}
pub struct Client(Mode);
impl Client {
    pub fn new(client: tokio_postgres::Client, write: bool) -> Self {
        if !write {
            return Self(Mode::Direct(client));
        }
        let (tx, rx) = mpsc::channel(1024);
        tokio::spawn(actor(client, rx));
        Self(Mode::Group(tx))
    }
    pub async fn query(
        &self,
        st: &Statement,
        params: &[&(dyn ToSql + Sync)],
    ) -> Result<Vec<Row>, Error> {
        match &self.0 {
            Mode::Direct(c) => c.query(st, params).await.map_err(Error::from),
            Mode::Group(tx) => {
                if params.len() != st.params().len() {
                    return Err(Error::Parameter("parameter count".into()));
                }
                let mut owned = Vec::with_capacity(params.len());
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
                let (reply, rx) = oneshot::channel();
                tx.send(Job {
                    statement: st.clone(),
                    params: owned,
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
    client
        .query_raw(&job.statement, job.params.iter())
        .await?
        .try_collect()
        .await
        .map_err(Error::from)
}
use futures_util::TryStreamExt;
async fn actor(client: tokio_postgres::Client, mut rx: mpsc::Receiver<Job>) {
    let delay = std::env::var("WRITE_BATCH_US")
        .ok()
        .map(|s| s.parse::<u64>().expect("WRITE_BATCH_US"))
        .unwrap_or(1000);
    while let Some(first) = rx.recv().await {
        let mut jobs = Vec::with_capacity(32);
        jobs.push(first);
        // Under load the preceding flush already collected a batch. At low load,
        // one millisecond gives concurrent writes a chance to share a flush.
        if rx.is_empty() {
            tokio::time::sleep(Duration::from_micros(delay)).await;
        }
        while jobs.len() < 128 {
            match rx.try_recv() {
                Ok(job) => jobs.push(job),
                Err(_) => break,
            }
        }
        if jobs.len() == 1 {
            let job = jobs.pop().unwrap();
            let result = execute(&client, &job).await;
            let _ = job.reply.send(result);
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
