//! Answers for the one-row-per-request statements: profile, current user, login lookup, and the tag list.
//!
//! These statements return exactly one row per request, in request order, with `ord` as the position in the group.
//! The rows are rendered by borrow into the response; the only owned data is a login's [`StoredUser`], because the
//! password thread outlives the arena the row sits in.

use std::time::Instant;

use crate::app::jobs::{PasswordJob, PasswordKind, ReadJob, StoredUser};
use crate::http::Status;
use crate::password::PasswordQueue;
use crate::pg::{Row, StmtResult};
use crate::render::{self, Profile, User};

use super::articles::{GroupCtx, optional_str};
use super::error::ReadError;
use super::sink::Sink;

/// Where a login continues. The password service implements it; tests collect the jobs instead.
pub trait PasswordSink {
    fn submit(&self, job: PasswordJob);
}

impl PasswordSink for PasswordQueue {
    fn submit(&self, job: PasswordJob) {
        self.push(job);
    }
}

const PROFILE_NOT_FOUND: &str = "profile not found";
const BAD_CREDENTIALS: &str = "invalid credentials";
const UNKNOWN_USER: &str = "user not found";

/// Columns shared by `profile.sql`, `current_user.sql` and `login.sql`: ord, id, username first.
const ORD: usize = 0;
const ID: usize = 1;
const USERNAME: usize = 2;

mod profile_col {
    pub const BIO: usize = 3;
    pub const IMAGE: usize = 4;
    pub const FOLLOWING: usize = 5;
}

/// `current_user.sql` and `login.sql` share: email, bio, image (and the hash for login).
mod user_col {
    pub const EMAIL: usize = 3;
    pub const BIO: usize = 4;
    pub const IMAGE: usize = 5;
    pub const PASSWORD_HASH: usize = 6;
}

/// Finds the job a row answers and marks it answered.
fn claim<'j>(
    row: Row<'_>,
    ctx: &GroupCtx<'j>,
    sink: &mut Sink,
) -> Result<(usize, &'j ReadJob), ReadError> {
    let member = sink.claim(row.i64(ORD)?)?;
    let at = ctx.members[member] as usize;
    Ok((at, &ctx.jobs[at]))
}

/// `GET /api/profiles/:username`
pub fn profiles(
    stmt: StmtResult<'_>,
    ctx: &GroupCtx<'_>,
    sink: &mut Sink,
) -> Result<(), ReadError> {
    for row in stmt.rows() {
        let (_, job) = claim(row, ctx, sink)?;
        if row.is_null(ID) {
            sink.error(job.origin, Status::NotFound, PROFILE_NOT_FOUND);
            continue;
        }
        sink.json(job.origin, Status::Ok, |w| {
            let profile = Profile {
                username: row.str(USERNAME)?,
                bio: optional_str(row, profile_col::BIO)?,
                image: optional_str(row, profile_col::IMAGE)?,
                following: row.bool(profile_col::FOLLOWING)?,
            };
            w.begin_object();
            w.key("profile");
            render::profile_object(w, &profile);
            w.end_object();
            Ok(())
        });
    }
    Ok(())
}

/// `GET /api/user`: the token in the answer is the one the request presented.
pub fn current_users(
    stmt: StmtResult<'_>,
    ctx: &GroupCtx<'_>,
    sink: &mut Sink,
) -> Result<(), ReadError> {
    for row in stmt.rows() {
        let (_, job) = claim(row, ctx, sink)?;
        if row.is_null(ID) {
            sink.error(job.origin, Status::Unauthorized, UNKNOWN_USER);
            continue;
        }
        sink.json(job.origin, Status::Ok, |w| {
            let user = User {
                email: row.str(user_col::EMAIL)?,
                token: job.token.text(&job.buf),
                username: row.str(USERNAME)?,
                bio: optional_str(row, user_col::BIO)?,
                image: optional_str(row, user_col::IMAGE)?,
            };
            w.begin_object();
            w.key("user");
            render::user_object(w, &user);
            w.end_object();
            Ok(())
        });
    }
    Ok(())
}

/// Login step 1. Unknown email: 401 now. Known: the job's own buffer moves to the password thread, which checks the
/// password and answers; the lane sends no reply.
pub fn logins(
    stmt: StmtResult<'_>,
    members: &[u32],
    jobs: &mut [ReadJob],
    sink: &mut Sink,
    passwords: &dyn PasswordSink,
) -> Result<(), ReadError> {
    for row in stmt.rows() {
        let member = sink.claim(row.i64(ORD)?)?;
        let job = &mut jobs[members[member] as usize];
        let stored = if row.is_null(ID) {
            None
        } else {
            stored_user(row)?
        };
        let Some(user) = stored else {
            sink.error(job.origin, Status::Unauthorized, BAD_CREDENTIALS);
            continue;
        };
        passwords.submit(PasswordJob {
            origin: job.origin,
            buf: std::mem::take(&mut job.buf),
            password: job.password,
            kind: PasswordKind::Verify { user },
            queued_at: Instant::now(),
        });
    }
    Ok(())
}

/// The user of a login row, or `None` when the stored hash is not a 60-byte bcrypt string (nothing could match it).
fn stored_user(row: Row<'_>) -> Result<Option<StoredUser>, ReadError> {
    let Ok(password_hash) = <[u8; 60]>::try_from(row.str(user_col::PASSWORD_HASH)?.as_bytes())
    else {
        return Ok(None);
    };
    Ok(Some(StoredUser {
        id: row.i64(ID)?,
        username: row.str(USERNAME)?.to_owned(),
        email: row.str(user_col::EMAIL)?.to_owned(),
        bio: optional_str(row, user_col::BIO)?.map(str::to_owned),
        image: optional_str(row, user_col::IMAGE)?.map(str::to_owned),
        password_hash,
    }))
}
