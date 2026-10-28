//! Test harness for the read side: a connection, the runner under test, the reference, request pools sampled from
//! the database, and the comparison helpers. Shared by the integration tests and the benchmarks.

use std::sync::Mutex;

use crate::app::jobs::{Field, ListKind, Origin, PasswordJob, ReadJob, ReadKind};
use crate::net::{ConnId, Reply};
use crate::pg::{Config as PgConfig, Connection, Results};

use super::reference::{Answer, Reference, Req};
use super::runner::{Health, Runner};
use super::session::{Db, SESSION_OPTIONS};
use super::simple::PasswordSink;

const DEFAULT_URL: &str = "postgres://conduit:conduit@127.0.0.1:5433/conduit_dev";
pub const TOKEN: &str = "header.payload.signature";

pub fn test_url() -> String {
    std::env::var("READ_TEST_URL").unwrap_or_else(|_| DEFAULT_URL.to_owned())
}

/// What a set of compared responses contained.
#[derive(Default, Debug)]
pub struct Coverage {
    pub responses: usize,
    pub substantial: usize,
    pub favorited: usize,
    pub following: usize,
    pub tagged: usize,
}

impl Coverage {
    fn add(&mut self, answer: &Answer) {
        let has = |needle: &[u8]| answer.body.windows(needle.len()).any(|w| w == needle);
        self.responses += 1;
        self.substantial += usize::from(answer.status == 200 && answer.body.len() > 100);
        self.favorited += usize::from(has(b"\"favorited\":true"));
        self.following += usize::from(has(b"\"following\":true"));
        self.tagged += usize::from(has(b"\"tagList\":[\""));
    }

    pub fn merge(&mut self, other: Coverage) {
        self.responses += other.responses;
        self.substantial += other.substantial;
        self.favorited += other.favorited;
        self.following += other.following;
        self.tagged += other.tagged;
    }
}

/// Collects the password jobs a batch hands over.
#[derive(Default)]
pub struct Collected(pub Mutex<Vec<PasswordJob>>);

impl PasswordSink for Collected {
    fn submit(&self, job: PasswordJob) {
        self.0.lock().unwrap().push(job);
    }
}

/// A connection, the runner under test and the reference, ready to run batches.
pub struct Harness {
    pub db: Db,
    pub runner: Runner,
    pub reference: Reference,
    pub reference_conn: Connection,
    pub passwords: Collected,
    pub results: Results,
    queries: usize,
}

impl Harness {
    pub fn open(url: &str) -> Harness {
        Harness::open_with(url, SESSION_OPTIONS)
    }

    /// Like [`open`](Self::open) with other session options for the lane's connection (experiments).
    pub fn open_with(url: &str, options: &str) -> Harness {
        let cfg = PgConfig::from_url(url).unwrap();
        let db = Db::open(&cfg, options).unwrap();
        let mut reference_conn = Connection::connect(&cfg, SESSION_OPTIONS).unwrap();
        let reference = Reference::prepare(&mut reference_conn).unwrap();
        Harness {
            db,
            runner: Runner::new(),
            reference,
            reference_conn,
            passwords: Collected::default(),
            results: Results::new(),
            queries: 0,
        }
    }

    pub fn connect() -> Harness {
        Harness::open(&test_url())
    }

    /// Runs `reqs` as one batch. Entry `i` is the response to `reqs[i]`, or `None` if the lane sent none.
    pub fn run_batch(&mut self, reqs: &[Req]) -> (Vec<Option<Answer>>, Health) {
        let mut jobs: Vec<ReadJob> = reqs
            .iter()
            .enumerate()
            .map(|(i, r)| to_job(r, i as u32))
            .collect();
        let health = self.runner.run(
            &mut self.db.conn,
            &self.db.stmts,
            &mut jobs,
            &self.passwords,
        );
        let mut answers = vec![None; reqs.len()];
        for reply in self.runner.replies() {
            answers[reply.conn.slot as usize] = Some(parse_reply(reply));
        }
        self.runner.recycle_requests(&mut jobs);
        (answers, health)
    }

    pub fn reference_answer(&mut self, req: &Req) -> Answer {
        self.reference
            .answer(&mut self.reference_conn, &mut self.results, req)
            .unwrap()
    }

    /// Runs the batch and checks every response against the reference.
    /// Returns what the compared responses contained, so a test can prove it compared real content (articles that
    /// are favorited, authors that are followed) and not a pile of empty pages.
    pub fn check_batch(&mut self, reqs: &[Req]) -> Coverage {
        let (answers, health) = self.run_batch(reqs);
        assert_eq!(health, Health::Good);
        let mut seen = Coverage::default();
        for (req, got) in reqs.iter().zip(answers) {
            let want = self.reference_answer(req);
            let got = got.expect("a response");
            assert_same(req, &got, &want);
            seen.add(&got);
        }
        seen
    }

    /// Text values of a one-column query (`::text` the column in the SQL).
    pub fn strings(&mut self, sql: &str) -> Vec<String> {
        self.queries += 1;
        let stmt = self
            .reference_conn
            .prepare(&format!("pool_query_{}", self.queries), sql, &[])
            .unwrap();
        self.reference_conn.push(&stmt, &[]).unwrap();
        self.reference_conn
            .flush_and_collect(&mut self.results)
            .unwrap();
        self.results
            .statement(0)
            .rows()
            .map(|r| r.str(0).unwrap().to_owned())
            .collect()
    }
}

pub fn to_job(req: &Req, slot: u32) -> ReadJob {
    let mut buf = Vec::new();
    let mut field = |text: &str| {
        let start = buf.len();
        buf.extend_from_slice(text.as_bytes());
        Field::new(start..buf.len())
    };
    let (key, token) = match req.kind {
        ReadKind::CurrentUser => (field(""), field(&req.key)),
        _ => (field(&req.key), field("")),
    };
    let password = field("password123");
    ReadJob {
        origin: Origin {
            conn: ConnId {
                io: 0,
                slot,
                generation: 0,
            },
            keep_alive: true,
        },
        kind: req.kind,
        buf,
        viewer: req.viewer,
        key,
        token,
        password,
        limit: req.limit,
        offset: req.offset,
        queued_at: std::time::Instant::now(),
    }
}

/// Splits `HTTP/1.1 200 OK ... \r\n\r\n body`.
pub fn parse_reply(reply: &Reply) -> Answer {
    let bytes = &reply.bytes[reply.start..];
    let head_end = bytes
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .expect("head terminator");
    let head = std::str::from_utf8(&bytes[..head_end]).unwrap();
    let status: u16 = head.split(' ').nth(1).unwrap().parse().unwrap();
    let declared: usize = head
        .lines()
        .find_map(|l| l.strip_prefix("Content-Length: "))
        .map_or(0, |n| n.parse().unwrap());
    let body = bytes[head_end + 4..].to_vec();
    assert_eq!(body.len(), declared, "Content-Length matches the body");
    Answer { status, body }
}

/// Success bodies must be identical bytes; for an error status the reference has no body, so the lane's body must be
/// the standard error document.
pub fn assert_same(req: &Req, got: &Answer, want: &Answer) {
    assert_eq!(
        got.status,
        want.status,
        "status of {req:?}: {}",
        String::from_utf8_lossy(&got.body)
    );
    if want.status == 200 {
        if got.body != want.body {
            let at = got
                .body
                .iter()
                .zip(&want.body)
                .position(|(a, b)| a != b)
                .unwrap_or(0);
            let show = |b: &[u8]| {
                String::from_utf8_lossy(&b[at.saturating_sub(60)..(at + 80).min(b.len())])
                    .into_owned()
            };
            panic!(
                "body of {req:?} differs at byte {at} (got {} bytes, want {})\n got: {}\nwant: {}",
                got.body.len(),
                want.body.len(),
                show(&got.body),
                show(&want.body)
            );
        }
    } else {
        assert!(
            got.body.starts_with(br#"{"errors":{"body":["#),
            "error body of {req:?}"
        );
    }
}

/// xorshift64*: enough randomness for choosing test inputs, and reproducible.
pub struct Rng(pub u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    pub fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

/// Values the random requests are drawn from, sampled from the database.
pub struct Pools {
    pub viewers: Vec<i64>,
    pub followers: Vec<i64>,
    /// Users who favorited one of the newest 20 articles, so the first page of a list shows `favorited: true`.
    pub favoriters_of_new: Vec<i64>,
    /// Users who follow the author of one of the newest articles.
    pub followers_of_new: Vec<i64>,
    pub slugs: Vec<String>,
    pub tags: Vec<String>,
    pub authors: Vec<String>,
    pub favoriters: Vec<String>,
    pub users: Vec<String>,
}

impl Pools {
    pub fn sample(h: &mut Harness) -> Pools {
        let ints = |v: Vec<String>| v.iter().map(|s| s.parse().unwrap()).collect::<Vec<i64>>();
        let viewers = ints(h.strings("select id::text from users order by random() limit 40"));
        let followers = ints(h.strings("select distinct follower_id::text from (select follower_id from follows order by random() limit 40) s"));
        let newest = "(select max(id) - 300 from articles)";
        let favoriters_of_new = ints(h.strings(
            "select distinct user_id::text from (select user_id from favorites where article_id > (select max(id) - 20 from articles) order by random() limit 60) s",
        ));
        let followers_of_new = ints(h.strings(&format!(
            "select distinct follower_id::text from (select follower_id from follows where followee_id in (select author_id from articles where id > {newest}) order by random() limit 60) s"
        )));
        Pools {
            viewers,
            followers,
            favoriters_of_new,
            followers_of_new,
            slugs: h.strings(&format!("select slug from articles where id > {newest} or random() < 0.003 limit 120")),
            tags: h.strings("select name from tags order by random() limit 20"),
            authors: h.strings("select u.username from users u where u.id in (select author_id from articles order by random() limit 40)"),
            favoriters: h.strings("select u.username from users u where u.id in (select user_id from favorites order by random() limit 40)"),
            users: h.strings("select username from users order by random() limit 40"),
        }
    }

    fn viewer(&self, rng: &mut Rng) -> i64 {
        match rng.below(8) {
            0 | 1 => 0,
            2 | 3 => *rng.pick(&self.favoriters_of_new),
            4 | 5 => *rng.pick(&self.followers_of_new),
            _ => *rng.pick(&self.viewers),
        }
    }

    /// A random request of any kind, with a small chance of an unknown tag, user or slug.
    pub fn request(&self, rng: &mut Rng) -> Req {
        const LIMITS: [i64; 6] = [1, 5, 10, 20, 50, 100];
        const OFFSETS: [i64; 7] = [0, 0, 0, 1, 10, 40, 100_000];
        let unknown = rng.below(8) == 0;
        let (limit, offset) = (*rng.pick(&LIMITS), *rng.pick(&OFFSETS));
        let viewer = self.viewer(rng);
        match rng.below(10) {
            0 => Req::list(ListKind::All, viewer, "", limit, offset),
            1 => Req::list(
                ListKind::Tag,
                viewer,
                if unknown {
                    "no-such-tag"
                } else {
                    rng.pick(&self.tags)
                },
                limit,
                offset,
            ),
            2 => Req::list(
                ListKind::Author,
                viewer,
                if unknown {
                    "nobody-here"
                } else {
                    rng.pick(&self.authors)
                },
                limit,
                offset,
            ),
            3 => Req::list(
                ListKind::Favorited,
                viewer,
                if unknown {
                    "nobody-here"
                } else {
                    rng.pick(&self.favoriters)
                },
                limit,
                offset,
            ),
            4 => Req::list(
                ListKind::Feed,
                *rng.pick(&self.followers),
                "",
                limit,
                offset,
            ),
            5 => Req::keyed(
                ReadKind::Article,
                viewer,
                if unknown {
                    "no-such-slug"
                } else {
                    rng.pick(&self.slugs)
                },
            ),
            6 => Req::keyed(
                ReadKind::Comments,
                viewer,
                if unknown {
                    "no-such-slug"
                } else {
                    rng.pick(&self.slugs)
                },
            ),
            7 => Req::keyed(
                ReadKind::Profile,
                viewer,
                if unknown {
                    "nobody-here"
                } else {
                    rng.pick(&self.users)
                },
            ),
            8 => Req::keyed(
                ReadKind::CurrentUser,
                if unknown {
                    999_999_999
                } else {
                    *rng.pick(&self.viewers)
                },
                TOKEN,
            ),
            _ => Req::keyed(ReadKind::Tags, 0, ""),
        }
    }
}
