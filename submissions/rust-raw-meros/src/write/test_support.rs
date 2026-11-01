//! Helpers shared by the integration tests and the benchmark: a lane driven without threads, job builders, a
//! response reader and plain SQL for checking what was stored. Compiled for tests only.
//!
//! The target database is `WRITE_TEST_URL`, default a copy of the seed:
//! `CREATE DATABASE write_test TEMPLATE conduit_dev OWNER conduit` (as the postgres superuser, port 5433).

use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use super::lane::Lane;
use crate::app::jobs::{Field, Origin, WriteJob, WriteKind};
use crate::app::slug::slugify;
use crate::config::Config;
use crate::json::{Value, parse};
use crate::jwt::Jwt;
use crate::net::{ConnId, Mailboxes, Reply};
use crate::pg::{self, Connection, Param, Results};

const DEFAULT_URL: &str = "postgres://conduit:conduit@127.0.0.1:5433/write_test";

pub fn test_url() -> String {
    std::env::var("WRITE_TEST_URL").unwrap_or_else(|_| DEFAULT_URL.to_owned())
}

pub fn test_config(url: &str) -> Config {
    Config {
        database_url: url.to_owned(),
        jwt_secret: b"test-secret".to_vec(),
        host: [127, 0, 0, 1],
        port: 0,
        io_threads: 1,
        read_lanes: 1,
        write_lanes: 1,
        read_window: Duration::ZERO,
        read_batch_max: 1,
        write_window: Duration::ZERO,
        write_batch_max: 1,
        bcrypt_threads: 1,
        bcrypt_window: Duration::ZERO,
    }
}

/// A name that no other test or earlier run used: lowercase letters and digits only.
pub fn unique(prefix: &str) -> String {
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    format!(
        "{prefix}{:x}{:x}",
        std::process::id(),
        nanos ^ COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

/// One lane plus the mailbox its replies land in.
pub struct Harness {
    pub lane: Lane,
    pub mailboxes: Mailboxes,
}

/// A decoded response.
#[derive(Debug, Clone)]
pub struct Resp {
    pub status: u16,
    pub body: String,
}

impl Harness {
    pub fn new() -> Harness {
        Harness::with_url(&test_url())
    }

    pub fn with_url(url: &str) -> Harness {
        let mailboxes = Mailboxes::new(1).expect("mailbox");
        let jwt = Arc::new(Jwt::new(b"test-secret"));
        let lane = Lane::start(&test_config(url), jwt, mailboxes.clone()).expect("lane starts");
        Harness { lane, mailboxes }
    }

    /// Runs `jobs` as ONE batch and returns the responses in job order.
    pub fn run(&mut self, mut jobs: Vec<WriteJob>) -> Vec<Resp> {
        let count = jobs.len();
        for (i, job) in jobs.iter_mut().enumerate() {
            job.origin.conn = ConnId {
                io: 0,
                slot: i as u32,
                generation: 0,
            };
        }
        self.lane.process(&mut jobs);
        let mut replies: Vec<Reply> = Vec::new();
        self.mailboxes.get(0).take_all(&mut replies);
        let mut ordered: Vec<Option<Resp>> = (0..count).map(|_| None).collect();
        for reply in replies {
            ordered[reply.conn.slot as usize] = Some(decode(&reply.bytes[reply.start..]));
        }
        ordered
            .into_iter()
            .map(|r| r.expect("every job is answered exactly once"))
            .collect()
    }

    pub fn run_one(&mut self, job: WriteJob) -> Resp {
        self.run(vec![job]).remove(0)
    }

    /// Runs every job as its own batch (its own transaction), in order.
    pub fn run_each(&mut self, jobs: Vec<WriteJob>) -> Vec<Resp> {
        jobs.into_iter().map(|job| self.run_one(job)).collect()
    }
}

fn decode(bytes: &[u8]) -> Resp {
    let text = String::from_utf8_lossy(bytes).into_owned();
    let status = text
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let body = text
        .split_once("\r\n\r\n")
        .map(|(_, b)| b.to_owned())
        .unwrap_or_default();
    Resp { status, body }
}

impl Resp {
    pub fn json(&self) -> Value<'_> {
        parse(self.body.as_bytes())
            .unwrap_or_else(|e| panic!("body {:?} is not JSON: {e}", self.body))
    }

    /// The text at a path such as `["article", "slug"]`.
    pub fn text(&self, path: &[&str]) -> String {
        let root = self.json();
        let mut at = &root;
        for key in path {
            at = at
                .get(key)
                .unwrap_or_else(|| panic!("no {key} in {}", self.body));
        }
        at.as_str()
            .unwrap_or_else(|| panic!("{path:?} is not a string in {}", self.body))
            .to_owned()
    }

    pub fn number(&self, path: &[&str]) -> i64 {
        let root = self.json();
        let mut at = &root;
        for key in path {
            at = at
                .get(key)
                .unwrap_or_else(|| panic!("no {key} in {}", self.body));
        }
        at.as_number()
            .and_then(|n| n.parse().ok())
            .unwrap_or_else(|| panic!("{path:?} is not a number in {}", self.body))
    }

    pub fn flag(&self, path: &[&str]) -> bool {
        let root = self.json();
        let mut at = &root;
        for key in path {
            at = at
                .get(key)
                .unwrap_or_else(|| panic!("no {key} in {}", self.body));
        }
        at.as_bool()
            .unwrap_or_else(|| panic!("{path:?} is not a bool in {}", self.body))
    }

    pub fn error_message(&self) -> String {
        let root = self.json();
        let message = root
            .get("errors")
            .and_then(|e| e.get("body"))
            .and_then(Value::as_array)
            .and_then(|a| a.first());
        message
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    }

    /// A string that is equal for two runs of the same script on different data: everything except ids, slugs,
    /// timestamps, tokens and the run's own names (`subs` replaces each name with a fixed stand-in).
    pub fn signature(&self, subs: &[(&str, &str)]) -> String {
        fn walk(value: &Value<'_>, subs: &[(&str, &str)], out: &mut String) {
            match value {
                Value::Object(members) => {
                    for (key, v) in members {
                        if matches!(&**key, "createdAt" | "updatedAt" | "token" | "slug" | "id") {
                            continue;
                        }
                        out.push_str(&format!("{key}="));
                        walk(v, subs, out);
                        out.push(';');
                    }
                }
                Value::Array(items) => {
                    out.push('[');
                    items.iter().for_each(|v| walk(v, subs, out));
                    out.push(']');
                }
                Value::String(s) => out.push_str(
                    &subs
                        .iter()
                        .fold(s.to_string(), |text, (from, to)| text.replace(from, to)),
                ),
                Value::Number(n) => out.push_str(n),
                Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
                Value::Null => out.push_str("null"),
            }
        }
        let mut out = format!("{}:", self.status);
        if !self.body.is_empty() {
            walk(&self.json(), subs, &mut out);
        }
        out
    }
}

/// Request bytes for one job, with the fields addressed as ranges.
#[derive(Default)]
pub struct Req {
    buf: Vec<u8>,
}

impl Req {
    pub fn new() -> Req {
        Req::default()
    }

    pub fn put(&mut self, text: &str) -> Field {
        let start = self.buf.len();
        self.buf.extend_from_slice(text.as_bytes());
        Field::new(start..self.buf.len())
    }

    pub fn opt(&mut self, text: Option<&str>) -> Option<Field> {
        text.map(|t| self.put(t))
    }

    pub fn job(self, viewer: i64, kind: WriteKind) -> WriteJob {
        let conn = ConnId {
            io: 0,
            slot: 0,
            generation: 0,
        };
        WriteJob {
            origin: Origin {
                conn,
                keep_alive: true,
            },
            viewer,
            buf: self.buf,
            kind,
        }
    }
}

pub fn hash() -> [u8; 60] {
    *b"$2a$10$abcdefghijklmnopqrstuuabcdefghijklmnopqrstuvwxyz01234"
}

pub fn register(username: &str, email: &str) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::Register {
        username: r.put(username),
        email: r.put(email),
        password_hash: hash(),
    };
    r.job(0, kind)
}

pub fn update_user(
    viewer: i64,
    email: Option<&str>,
    username: Option<&str>,
    bio: Option<&str>,
) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::UpdateUser {
        email: r.opt(email),
        username: r.opt(username),
        password_hash: None,
        bio: r.opt(bio),
        image: None,
        token: r.put("presented.token.value"),
    };
    r.job(viewer, kind)
}

pub fn follow(viewer: i64, username: &str, follow: bool) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::Follow {
        username: r.put(username),
        follow,
    };
    r.job(viewer, kind)
}

pub fn create_article(viewer: i64, title: &str, tags: &[&str]) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::CreateArticle {
        slug_base: slugify(title),
        title: r.put(title),
        description: r.put("About it"),
        body: r.put("The body"),
        tags: tags.iter().map(|t| r.put(t)).collect(),
    };
    r.job(viewer, kind)
}

pub fn update_article(
    viewer: i64,
    slug: &str,
    title: Option<&str>,
    body: Option<&str>,
) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::UpdateArticle {
        slug: r.put(slug),
        slug_base: title.map(slugify),
        title: r.opt(title),
        description: None,
        body: r.opt(body),
    };
    r.job(viewer, kind)
}

pub fn delete_article(viewer: i64, slug: &str) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::DeleteArticle { slug: r.put(slug) };
    r.job(viewer, kind)
}

pub fn favorite(viewer: i64, slug: &str, favorite: bool) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::Favorite {
        slug: r.put(slug),
        favorite,
    };
    r.job(viewer, kind)
}

pub fn add_comment(viewer: i64, slug: &str, body: &str) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::AddComment {
        slug: r.put(slug),
        body: r.put(body),
    };
    r.job(viewer, kind)
}

pub fn delete_comment(viewer: i64, slug: &str, comment_id: i64) -> WriteJob {
    let mut r = Req::new();
    let kind = WriteKind::DeleteComment {
        slug: r.put(slug),
        comment_id,
    };
    r.job(viewer, kind)
}

/// First column of the first row of `sql`, as text (`NULL` for SQL NULL, empty for no row). Uses a fresh
/// connection, so it sees only committed data.
pub fn scalar(sql: &str) -> String {
    let config = pg::Config::from_url(&test_url()).expect("url");
    let mut conn = Connection::connect(&config, "").expect("connect");
    let wrapped = format!("select v::text from ({sql}) as q(v) limit 1");
    let stmt = conn.prepare("scalar", &wrapped, &[]).expect("prepare");
    let mut results = Results::new();
    conn.push(&stmt, &[] as &[Param<'_>]).expect("push");
    conn.flush_and_collect(&mut results).expect("run");
    let result = results.statement(0);
    if let Some(e) = result.error() {
        panic!("{sql}: {e}");
    }
    match result.row(0) {
        None => String::new(),
        Some(row) if row.is_null(0) => "NULL".to_owned(),
        Some(row) => row.str(0).expect("text").to_owned(),
    }
}

pub fn count(sql: &str) -> i64 {
    scalar(sql).parse().expect("a count")
}

/// Id of a user by name, from the database.
pub fn user_id(username: &str) -> i64 {
    count(&format!(
        "select id::text from users where username = '{username}'"
    ))
}

/// Registers a user through the lane and returns its id.
pub fn new_user(h: &mut Harness, prefix: &str) -> (i64, String) {
    let name = unique(prefix);
    let resp = h.run_one(register(&name, &format!("{name}@example.com")));
    assert_eq!(resp.status, 201, "{}", resp.body);
    (user_id(&name), name)
}

/// Creates an article through the lane and returns its slug.
pub fn new_article(h: &mut Harness, author: i64, tags: &[&str]) -> String {
    let resp = h.run_one(create_article(
        author,
        &format!("Title {}", unique("t")),
        tags,
    ));
    assert_eq!(resp.status, 201, "{}", resp.body);
    resp.text(&["article", "slug"])
}

/// The lines of `EXPLAIN` for `sql` (no parameters), joined with newlines.
pub fn plan_text(sql: &str) -> String {
    let config = pg::Config::from_url(&test_url()).expect("url");
    let mut conn = Connection::connect(&config, "").expect("connect");
    let stmt = conn
        .prepare("plan", &format!("explain {sql}"), &[])
        .expect("prepare");
    let mut results = Results::new();
    conn.push(&stmt, &[] as &[Param<'_>]).expect("push");
    conn.flush_and_collect(&mut results).expect("run");
    let lines: Vec<&str> = results
        .statement(0)
        .rows()
        .filter_map(|row| row.str(0).ok())
        .collect();
    lines.join("\n")
}
