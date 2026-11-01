//! Turns verdicts into effects: a login answer, a 401, a 500, or a hashed write handed on.
//!
//! Buffer discipline: the request buffer of a login goes back to the pool after the answer is rendered (the
//! stored user strings are dropped with the job). The request buffer of a hash job is *moved* into the follow-up
//! write job; nothing is copied.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::app::jobs::{PasswordJob, PasswordKind, StoredUser, WriteJob, WriteKind};
use crate::http::{ResponseBuf, Status};
use crate::json::JsonWriter;
use crate::jwt::Jwt;
use crate::net::Reply;
use crate::pool::POOL;
use crate::render::{User, user_object};

use super::TOKEN_TTL_SECS;
use super::compute::Verdict;
use super::outbox::Outbox;

const MSG_INVALID_CREDENTIALS: &str = "invalid credentials";
const MSG_INTERNAL: &str = "internal error";

/// Per-worker finishing state: the destination, the signer and a reusable token buffer.
pub struct Finisher<'a, O: Outbox> {
    outbox: &'a O,
    jwt: &'a Jwt,
    token: Vec<u8>,
}

impl<'a, O: Outbox> Finisher<'a, O> {
    pub fn new(outbox: &'a O, jwt: &'a Jwt) -> Self {
        Finisher {
            outbox,
            jwt,
            token: Vec::with_capacity(crate::jwt::MAX_TOKEN_LEN),
        }
    }

    /// Finishes every job of `batch` (emptying it) with the verdict at the same position.
    pub fn finish_all(&mut self, batch: &mut Vec<PasswordJob>, verdicts: &[Verdict]) {
        for (job, verdict) in batch.drain(..).zip(verdicts) {
            self.finish(job, *verdict);
        }
    }

    fn finish(&mut self, job: PasswordJob, verdict: Verdict) {
        let PasswordJob {
            origin, buf, kind, ..
        } = job;
        match (kind, verdict) {
            (PasswordKind::Verify { user }, Verdict::Match) => {
                self.answer_login(origin, &user);
                POOL.put(buf);
            }
            (PasswordKind::Verify { .. }, Verdict::Mismatch) => {
                self.answer_error(origin, Status::Unauthorized, MSG_INVALID_CREDENTIALS);
                POOL.put(buf);
            }
            (PasswordKind::Hash { then }, Verdict::Hashed(hash)) => self.hand_on(*then, buf, hash),
            (PasswordKind::Hash { then }, _) => {
                self.answer_error(origin, Status::Internal, MSG_INTERNAL);
                POOL.put(buf);
                POOL.put(then.buf);
            }
            (PasswordKind::Verify { .. }, _) => {
                self.answer_error(origin, Status::Internal, MSG_INTERNAL);
                POOL.put(buf);
            }
        }
    }

    /// Fills the hash into the follow-up write and sends it on. The request buffer ends up in exactly one place.
    fn hand_on(&self, mut then: WriteJob, own_buf: Vec<u8>, hash: [u8; crate::bcrypt::HASH_LEN]) {
        let stored = match &mut then.kind {
            WriteKind::Register { password_hash, .. } => {
                *password_hash = hash;
                true
            }
            WriteKind::UpdateUser { password_hash, .. } => {
                *password_hash = Some(hash);
                true
            }
            _ => false,
        };
        if !stored {
            self.answer_error(then.origin, Status::Internal, MSG_INTERNAL);
            POOL.put(own_buf);
            POOL.put(then.buf);
            return;
        }
        if then.buf.is_empty() {
            then.buf = own_buf; // the buffer travels with the write: a move
        } else {
            POOL.put(own_buf);
        }
        self.outbox.write(then);
    }

    /// 200 with the user object and a fresh token.
    fn answer_login(&mut self, origin: crate::app::jobs::Origin, user: &StoredUser) {
        let now = unix_now();
        self.token.clear();
        self.jwt
            .sign(user.id as u64, now, now + TOKEN_TTL_SECS, &mut self.token);
        let token = std::str::from_utf8(&self.token).unwrap_or("");
        let mut out = ResponseBuf::from_vec(POOL.get());
        out.begin();
        let mut w = JsonWriter::new(out.body());
        w.begin_object();
        w.key("user");
        user_object(
            &mut w,
            &User {
                email: &user.email,
                token,
                username: &user.username,
                bio: user.bio.as_deref(),
                image: user.image.as_deref(),
            },
        );
        w.end_object();
        let start = out.finish(Status::Ok, origin.keep_alive);
        self.outbox.reply(Reply {
            conn: origin.conn,
            bytes: out.into_vec(),
            start,
            close: !origin.keep_alive,
        });
    }

    fn answer_error(&self, origin: crate::app::jobs::Origin, status: Status, message: &str) {
        let mut out = ResponseBuf::from_vec(POOL.get());
        let start = out.finish_error(status, origin.keep_alive, message);
        self.outbox.reply(Reply {
            conn: origin.conn,
            bytes: out.into_vec(),
            start,
            close: !origin.keep_alive,
        });
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}
