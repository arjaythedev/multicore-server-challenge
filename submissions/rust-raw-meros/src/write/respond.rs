//! Building and delivering the responses of a batch.
//!
//! A [`Responder`] is owned by one lane and reused for every batch: the token scratch, the per-owner reply lists
//! and the list of request buffers to give back all keep their capacity, so a steady-state batch allocates
//! nothing here. Response buffers come from [`POOL`] and travel to the io thread inside the [`Reply`].

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use super::bodies::{self, Kind, Verdict};
use super::finding::{Failure, Finding};
use crate::app::jobs::{WriteJob, WriteKind};
use crate::http::{ResponseBuf, Status};
use crate::jwt::Jwt;
use crate::net::{Mailboxes, Reply};
use crate::pg::PgError;
use crate::pool::POOL;

/// A token is valid for 30 days (SPEC.md).
pub const TOKEN_LIFETIME_SECS: u64 = 30 * 24 * 3600;

const INTERNAL: &str = "internal error";
const UNKNOWN_OUTCOME: &str = "the write may not have been committed; try again";

pub struct Responder {
    jwt: Arc<Jwt>,
    /// Scratch for one token; ASCII (base64url and dots).
    token: Vec<u8>,
    /// Replies per owning io thread, indexed by `ConnId::io`.
    outbox: Vec<Vec<Reply>>,
    /// Request buffers waiting to go back to the pool.
    recycled: Vec<Vec<u8>>,
}

impl Responder {
    pub fn new(jwt: Arc<Jwt>) -> Responder {
        Responder {
            jwt,
            token: Vec::with_capacity(256),
            outbox: Vec::new(),
            recycled: Vec::new(),
        }
    }

    /// Renders the response for `job` into a pooled buffer and queues it for delivery.
    pub fn answer(&mut self, job: &WriteJob, finding: Finding<'_>) {
        let keep_alive = job.origin.keep_alive;
        let mut response = ResponseBuf::from_vec(POOL.get());
        response.begin();
        let verdict = self
            .verdict(job, finding, response.body())
            .unwrap_or(Verdict::Error(Status::Internal, INTERNAL));
        let start = match verdict {
            Verdict::Body(status) => response.finish(status, keep_alive),
            Verdict::Error(status, message) => response.finish_error(status, keep_alive, message),
        };
        let reply = Reply {
            conn: job.origin.conn,
            bytes: response.into_vec(),
            start,
            close: !keep_alive,
        };
        let io = usize::from(job.origin.conn.io);
        if self.outbox.len() <= io {
            self.outbox.resize_with(io + 1, Vec::new);
        }
        self.outbox[io].push(reply);
    }

    /// Hands a request buffer back once the batch is done with it.
    pub fn recycle(&mut self, buf: Vec<u8>) {
        self.recycled.push(buf);
    }

    /// Posts every queued reply (one wake-up per io thread) and returns the request buffers to the pool.
    /// Call only after the transaction of the batch has been committed (or has failed for good).
    pub fn deliver(&mut self, mailboxes: &Mailboxes) {
        for (io, replies) in self.outbox.iter_mut().enumerate() {
            mailboxes.get(io).post_all(replies);
        }
        POOL.put_all(&mut self.recycled);
    }

    /// Decides the status and writes the body. `Err` means a row did not have the shape the SQL promises.
    fn verdict(
        &mut self,
        job: &WriteJob,
        finding: Finding<'_>,
        out: &mut Vec<u8>,
    ) -> Result<Verdict, PgError> {
        let result = match finding {
            Finding::Done(result) => result,
            Finding::Rejected => return Ok(Verdict::Error(Status::Internal, INTERNAL)),
            Finding::Unknown => {
                return Ok(Verdict::Error(Status::ServiceUnavailable, UNKNOWN_OUTCOME));
            }
            Finding::Failed(failure) => return Ok(failed(&job.kind, failure)),
        };
        match &job.kind {
            WriteKind::Register { .. } => {
                let Some(id) = bodies::user_id(&result)? else {
                    return bodies::register(&result, "", out);
                };
                let token = self.sign(id)?;
                bodies::register(&result, token, out)
            }
            WriteKind::UpdateUser { token, .. } => {
                bodies::update_user(&result, token.text(&job.buf), out)
            }
            WriteKind::Follow { follow, .. } => bodies::profile(&result, *follow, out),
            WriteKind::CreateArticle { .. } => bodies::article(&result, Status::Created, out),
            WriteKind::UpdateArticle { .. } => bodies::update_article(&result, out),
            WriteKind::DeleteArticle { .. } => bodies::removal(&result, Kind::Article),
            WriteKind::Favorite { .. } => bodies::article(&result, Status::Ok, out),
            WriteKind::AddComment { .. } => bodies::comment(&result, out),
            WriteKind::DeleteComment { .. } => bodies::removal(&result, Kind::Comment),
        }
    }

    /// A fresh token for `user_id`, valid from now for [`TOKEN_LIFETIME_SECS`]. Borrowed from the scratch buffer.
    fn sign(&mut self, user_id: i64) -> Result<&str, PgError> {
        let id =
            u64::try_from(user_id).map_err(|_| PgError::Protocol("negative user id".into()))?;
        let now = unix_seconds();
        self.token.clear();
        self.jwt
            .sign(id, now, now + TOKEN_LIFETIME_SECS, &mut self.token);
        std::str::from_utf8(&self.token).map_err(|_| PgError::Protocol("token is not ASCII".into()))
    }
}

/// Seconds since the Unix epoch; 0 if the clock is before it.
pub fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// The answer for a job whose statements failed. A unique violation is the client's fault only where the request
/// can collide on username or email.
fn failed(kind: &WriteKind, failure: Failure) -> Verdict {
    match (failure, kind) {
        (Failure::UniqueViolation, WriteKind::Register { .. } | WriteKind::UpdateUser { .. }) => {
            Verdict::Error(Status::Unprocessable, bodies::TAKEN)
        }
        _ => Verdict::Error(Status::Internal, INTERNAL),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::jobs::Field;

    fn update_user() -> WriteKind {
        WriteKind::UpdateUser {
            email: None,
            username: None,
            password_hash: None,
            bio: None,
            image: None,
            token: Field::default(),
        }
    }

    #[test]
    fn a_unique_violation_is_422_only_for_user_writes() {
        let taken = Verdict::Error(Status::Unprocessable, bodies::TAKEN);
        assert_eq!(failed(&update_user(), Failure::UniqueViolation), taken);
        let delete = WriteKind::DeleteArticle {
            slug: Field::default(),
        };
        assert_eq!(
            failed(&delete, Failure::UniqueViolation),
            Verdict::Error(Status::Internal, INTERNAL)
        );
        assert_eq!(
            failed(&update_user(), Failure::Server),
            Verdict::Error(Status::Internal, INTERNAL)
        );
        assert_eq!(
            failed(&update_user(), Failure::NotRun),
            Verdict::Error(Status::Internal, INTERNAL)
        );
    }

    #[test]
    fn tokens_verify_and_expire_after_thirty_days() {
        let jwt = Arc::new(Jwt::new(b"secret"));
        let mut responder = Responder::new(Arc::clone(&jwt));
        let token = responder.sign(42).map(str::to_owned).unwrap();
        let now = unix_seconds();
        assert_eq!(jwt.verify(token.as_bytes(), now), Ok(42));
        assert!(
            jwt.verify(token.as_bytes(), now + TOKEN_LIFETIME_SECS + 5)
                .is_err()
        );
        assert!(responder.sign(-1).is_err());
    }

    #[test]
    fn unknown_and_rejected_jobs_get_503_and_500() {
        use crate::app::jobs::Origin;
        use crate::net::ConnId;
        let mut responder = Responder::new(Arc::new(Jwt::new(b"s")));
        let conn = ConnId {
            io: 1,
            slot: 3,
            generation: 0,
        };
        let job = WriteJob {
            origin: Origin {
                conn,
                keep_alive: false,
            },
            viewer: 1,
            buf: Vec::new(),
            kind: WriteKind::DeleteArticle {
                slug: Field::default(),
            },
        };
        responder.answer(&job, Finding::Unknown);
        responder.answer(&job, Finding::Rejected);
        let replies = &responder.outbox[1];
        assert_eq!(replies.len(), 2);
        assert!(replies[0].bytes[replies[0].start..].starts_with(b"HTTP/1.1 503"));
        assert!(replies[1].bytes[replies[1].start..].starts_with(b"HTTP/1.1 500"));
        assert!(replies.iter().all(|r| r.close && r.conn == conn));
        assert!(responder.outbox[0].is_empty());
    }
}
