//! One interleaved bcrypt call for a whole batch, hash and verify jobs together.
//!
//! A verify is a hash with the stored salt and cost whose digest is compared afterwards; a hash gets a fresh random
//! salt. Both become [`HashJob`] lanes of the same `hash_many` call, so the interleaving does not care what the
//! lane is for. A job that needs no computation (malformed stored hash, no randomness) gets its verdict directly.

use crate::app::jobs::{PasswordJob, PasswordKind};
use crate::bcrypt::{self, DIGEST_BYTES, HASH_LEN, HashJob, MAX_LANES};
use crate::crypto::{ct, random};

use super::BCRYPT_COST;

/// Outcome of one job.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Verify: the password matches the stored hash.
    Match,
    /// Verify: it does not (or the stored hash is malformed).
    Mismatch,
    /// Hash: the finished 60-byte hash string.
    Hashed([u8; HASH_LEN]),
    /// Hash: no salt could be drawn from the system, or the job kind is inconsistent.
    Failed,
    /// Internal, while the batch runs: the result is lane `n`.
    Pending(usize),
}

/// What the plan for one job is.
enum Plan {
    Lane {
        job: HashJob<'static>,
        expected: Option<[u8; DIGEST_BYTES]>,
    },
    Done(Verdict),
}

/// Reusable per-worker state: the verdict list keeps its allocation between batches.
pub struct Computer {
    verdicts: Vec<Verdict>,
}

impl Computer {
    pub fn new() -> Computer {
        Computer {
            verdicts: Vec::with_capacity(MAX_LANES),
        }
    }

    /// Verdicts of the last `compute`, in batch order.
    pub fn verdicts(&self) -> &[Verdict] {
        &self.verdicts
    }

    /// Computes the batch (at most [`MAX_LANES`] jobs) in one interleaved call.
    pub fn compute(&mut self, batch: &[PasswordJob]) {
        self.verdicts.clear();
        let mut jobs = [HashJob {
            password: &[],
            salt: [0; 16],
            cost: 0,
        }; MAX_LANES];
        let mut expected = [None; MAX_LANES];
        let mut lanes = 0;
        for job in batch.iter().take(MAX_LANES) {
            match plan(job) {
                Plan::Lane {
                    job: lane,
                    expected: want,
                } => {
                    jobs[lanes] = HashJob {
                        password: password_of(job),
                        ..lane
                    };
                    expected[lanes] = want;
                    self.verdicts.push(Verdict::Pending(lanes));
                    lanes += 1;
                }
                Plan::Done(verdict) => self.verdicts.push(verdict),
            }
        }
        let digests = bcrypt::hash_many(&jobs[..lanes]);
        for verdict in &mut self.verdicts {
            if let Verdict::Pending(lane) = *verdict {
                *verdict = settle(&jobs[lane], expected[lane], &digests[lane]);
            }
        }
    }
}

/// The password bytes of a job. A hash job may carry its request buffer in the follow-up write (`then.buf`)
/// instead of its own: then its own buffer is empty and the follow-up holds the bytes.
pub fn password_of(job: &PasswordJob) -> &[u8] {
    let buf = match &job.kind {
        PasswordKind::Hash { then } if job.buf.is_empty() => &then.buf,
        _ => &job.buf,
    };
    buf.get(job.password.start as usize..job.password.end as usize)
        .unwrap_or(&[])
}

/// Decides how a job takes part: as a lane (with salt and cost; the password is filled in by the caller) or not.
fn plan(job: &PasswordJob) -> Plan {
    match &job.kind {
        PasswordKind::Verify { user } => match bcrypt::parse(&user.password_hash) {
            Some(stored) => Plan::Lane {
                job: HashJob {
                    password: &[],
                    salt: stored.salt,
                    cost: stored.cost,
                },
                expected: Some(stored.digest),
            },
            None => Plan::Done(Verdict::Mismatch),
        },
        PasswordKind::Hash { .. } => {
            let mut salt = [0u8; 16];
            match random::fill(&mut salt) {
                Ok(()) => Plan::Lane {
                    job: HashJob {
                        password: &[],
                        salt,
                        cost: BCRYPT_COST,
                    },
                    expected: None,
                },
                Err(_) => Plan::Done(Verdict::Failed),
            }
        }
    }
}

/// Turns a lane's digest into the verdict: compare (verify) or encode (hash).
fn settle(
    lane: &HashJob,
    expected: Option<[u8; DIGEST_BYTES]>,
    digest: &[u8; DIGEST_BYTES],
) -> Verdict {
    match expected {
        Some(want) if ct::eq(&want, digest) => Verdict::Match,
        Some(_) => Verdict::Mismatch,
        None => Verdict::Hashed(bcrypt::encode(lane.cost, &lane.salt, digest)),
    }
}
