//! The application layer between the io threads and the lanes: parse, authenticate, route, validate, and either
//! answer at once (errors, nothing to ask Postgres) or turn the request into a job.
//!
//! A job takes over the request buffer (moved, not copied; see DESIGN.md "Zero-copy rules"). Everything the lanes need
//! from the request is a [`Field`](jobs::Field) range into that buffer.

pub mod auth;
pub mod body;
pub mod jobs;
pub mod route;
pub mod scratch;
pub mod slug;

mod plan;

use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use self::jobs::{Origin, PasswordJob, PasswordKind, ReadJob, WriteJob};
use self::plan::{Plan, ReadPlan};
use self::scratch::Scratch;
use crate::http::{Parse, ResponseBuf, Status};
use crate::jwt::Jwt;
use crate::net::{ConnId, Step};
use crate::password::PasswordQueue;
use crate::read::ReadQueue;
use crate::write::WriteQueue;

/// Admission control. A queue this long is a backlog of more than half a second at the rates the server reaches, so a
/// request that joins it would wait for longer than the clients tolerate while its buffer pins memory. Beyond the
/// limit a request is answered 503 at once: the admitted requests keep their latency, memory stays bounded, and the
/// server recovers as soon as the load drops. Only real overload gets here (under the p95 limit the queues hold a
/// few batches).
const MAX_QUEUED_READS: usize = 24_576;
const MAX_QUEUED_WRITES: usize = 8_192;
/// Registrations and password changes wait for bcrypt: about 30 hashes per second at the highest load we measured,
/// so 4,096 waiting jobs are already more than the 8 s shed limit of the password threads can ever serve.
const MAX_QUEUED_HASHES: usize = 4_096;

/// Shared by all io threads.
pub struct App {
    jwt: Arc<Jwt>,
    read: Arc<ReadQueue>,
    write: Arc<WriteQueue>,
    password: Arc<PasswordQueue>,
}

impl App {
    pub fn new(
        jwt: Arc<Jwt>,
        read: Arc<ReadQueue>,
        write: Arc<WriteQueue>,
        password: Arc<PasswordQueue>,
    ) -> App {
        App {
            jwt,
            read,
            write,
            password,
        }
    }

    /// Handles the bytes read for one connection: see [`Step`] for the four outcomes.
    pub fn handle(&self, buf: Vec<u8>, conn: ConnId, out: &mut ResponseBuf) -> Step {
        let mut scratch = Scratch::default();
        let (plan, consumed, keep_alive) = match crate::http::parse_request(&buf) {
            Parse::Incomplete => return Step::NeedMore(buf),
            Parse::Bad(status) => {
                let start = out.finish_error(status, false, status_message(status));
                return Step::Failed { buf, start };
            }
            Parse::Request(req) => (
                plan::plan(&self.jwt, unix_seconds(), &buf, &req, &mut scratch),
                req.consumed,
                req.keep_alive,
            ),
        };
        let origin = Origin { conn, keep_alive };
        match self.admit(plan) {
            Plan::Reject(status, message) => {
                let start = out.finish_error(status, keep_alive, message);
                Step::Answered {
                    buf,
                    consumed,
                    start,
                    keep_alive,
                }
            }
            Plan::Read(read) => self.queue_read(buf, consumed, origin, read, scratch),
            Plan::Write { viewer, kind } => {
                self.queue_write(buf, consumed, origin, viewer, kind, scratch)
            }
            Plan::Hash {
                viewer,
                password,
                then,
            } => self.queue_hash(buf, consumed, origin, viewer, password, then, scratch),
        }
    }

    fn queue_read(
        &self,
        mut buf: Vec<u8>,
        consumed: usize,
        origin: Origin,
        mut plan: ReadPlan,
        scratch: Scratch,
    ) -> Step {
        let rest = buf.split_off(consumed);
        scratch.commit(&mut buf, plan.fields_mut());
        self.read.push(ReadJob {
            origin,
            kind: plan.kind,
            buf,
            viewer: plan.viewer,
            key: plan.key,
            token: plan.token,
            password: plan.password,
            limit: plan.limit,
            offset: plan.offset,
            queued_at: Instant::now(),
        });
        Step::Queued { rest }
    }

    fn queue_write(
        &self,
        mut buf: Vec<u8>,
        consumed: usize,
        origin: Origin,
        viewer: i64,
        mut kind: jobs::WriteKind,
        scratch: Scratch,
    ) -> Step {
        let rest = buf.split_off(consumed);
        scratch.commit(&mut buf, plan::write_fields_mut(&mut kind));
        self.write.push(WriteJob {
            origin,
            viewer,
            buf,
            kind,
        });
        Step::Queued { rest }
    }

    /// Admission control: a request that would join an over-long queue is rejected with 503 instead.
    fn admit(&self, plan: Plan) -> Plan {
        let overloaded = match plan {
            Plan::Read(_) => self.read.len() > MAX_QUEUED_READS,
            Plan::Write { .. } => self.write.len() > MAX_QUEUED_WRITES,
            Plan::Hash { .. } => self.password.len() > MAX_QUEUED_HASHES,
            _ => false,
        };
        if overloaded {
            Plan::Reject(Status::ServiceUnavailable, MSG_BUSY)
        } else {
            plan
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn queue_hash(
        &self,
        mut buf: Vec<u8>,
        consumed: usize,
        origin: Origin,
        viewer: i64,
        mut password: jobs::Field,
        mut then: jobs::WriteKind,
        scratch: Scratch,
    ) -> Step {
        let rest = buf.split_off(consumed);
        let fields = plan::write_fields_mut(&mut then)
            .into_iter()
            .chain([&mut password]);
        scratch.commit(&mut buf, fields);
        self.password.push(PasswordJob {
            origin,
            buf,
            password,
            kind: PasswordKind::Hash {
                then: Box::new(WriteJob {
                    origin,
                    viewer,
                    buf: Vec::new(),
                    kind: then,
                }),
            },
            queued_at: Instant::now(),
        });
        Step::Queued { rest }
    }
}

const MSG_BUSY: &str = "server is busy, try again";

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn status_message(status: Status) -> &'static str {
    match status {
        Status::LengthRequired => "chunked request bodies are not supported",
        Status::PayloadTooLarge => "request body too large",
        Status::RequestHeaderFieldsTooLarge => "request headers too large",
        _ => "malformed request",
    }
}
