//! Queue rule tests and end-to-end tests with a capturing outbox (no socket, no database). The stored hash is the
//! one every seeded user of `conduit_dev` has, for the password `password123`.

use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::outbox::Outbox;
use super::*;
use crate::app::jobs::{Field, Origin, PasswordJob, PasswordKind, StoredUser, WriteJob, WriteKind};
use crate::bcrypt::MAX_LANES;
use crate::json::{self, Value};
use crate::net::{ConnId, Reply};

const SEEDED_HASH: &[u8; 60] = b"$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
const PASSWORD: &[u8] = b"password123";
const SECRET: &[u8] = b"test-secret";
const RECEIVE_TIMEOUT: Duration = Duration::from_secs(30);

enum Event {
    Reply(Reply),
    Write(Box<WriteJob>),
}

struct Capture(Mutex<Sender<Event>>);

impl Outbox for Capture {
    fn reply(&self, reply: Reply) {
        let _ = self.0.lock().unwrap().send(Event::Reply(reply));
    }
    fn write(&self, job: WriteJob) {
        let _ = self.0.lock().unwrap().send(Event::Write(Box::new(job)));
    }
}

/// A running worker with a queue and the receiving end of its outbox.
struct Rig {
    queue: Arc<PasswordQueue>,
    events: Receiver<Event>,
    worker: Option<std::thread::JoinHandle<()>>,
    jwt: Arc<Jwt>,
}

impl Rig {
    fn new(window: Duration) -> Rig {
        let queue = PasswordQueue::new(window);
        let (tx, events) = channel();
        let jwt = Arc::new(Jwt::new(SECRET));
        let worker = {
            let (queue, jwt) = (queue.clone(), jwt.clone());
            std::thread::spawn(move || run(&queue, &Capture(Mutex::new(tx)), &jwt))
        };
        Rig {
            queue,
            events,
            worker: Some(worker),
            jwt,
        }
    }

    fn next(&self) -> Event {
        self.events
            .recv_timeout(RECEIVE_TIMEOUT)
            .expect("worker answered")
    }

    fn reply(&self) -> (u16, String) {
        match self.next() {
            Event::Reply(r) => (status_of(&r), body_of(&r)),
            Event::Write(_) => panic!("expected a reply"),
        }
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.queue.close();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn status_of(r: &Reply) -> u16 {
    let line = std::str::from_utf8(&r.bytes[r.start..r.start + 12]).unwrap();
    line[9..12].parse().unwrap()
}

fn body_of(r: &Reply) -> String {
    let text = std::str::from_utf8(&r.bytes[r.start..]).unwrap();
    text.split_once("\r\n\r\n").unwrap().1.to_owned()
}

fn origin(slot: u32) -> Origin {
    Origin {
        conn: ConnId {
            io: 0,
            slot,
            generation: 1,
        },
        keep_alive: true,
    }
}

fn request_buf(password: &[u8]) -> (Vec<u8>, Field) {
    let mut buf = b"junk".to_vec();
    let start = buf.len();
    buf.extend_from_slice(password);
    (buf, Field::new(start..start + password.len()))
}

fn user(id: i64, hash: [u8; 60]) -> StoredUser {
    StoredUser {
        id,
        username: "ann".into(),
        email: "ann@example.com".into(),
        bio: None,
        image: Some("i.png".into()),
        password_hash: hash,
    }
}

fn verify_job(slot: u32, id: i64, password: &[u8]) -> PasswordJob {
    let (buf, field) = request_buf(password);
    PasswordJob {
        origin: origin(slot),
        buf,
        password: field,
        kind: PasswordKind::Verify {
            user: user(id, *SEEDED_HASH),
        },
        queued_at: Instant::now(),
    }
}

fn write_job(kind: WriteKind, buf: Vec<u8>) -> Box<WriteJob> {
    Box::new(WriteJob {
        origin: origin(9),
        viewer: 0,
        buf,
        kind,
    })
}

fn register_kind() -> WriteKind {
    WriteKind::Register {
        username: Field::default(),
        email: Field::default(),
        password_hash: [0; 60],
    }
}

/// Hash job whose request buffer travels in `then` (the app's choice), leaving the job's own buffer empty.
fn hash_job_buffer_in_then(kind: WriteKind, password: &[u8]) -> PasswordJob {
    let (buf, field) = request_buf(password);
    PasswordJob {
        origin: origin(9),
        buf: Vec::new(),
        password: field,
        kind: PasswordKind::Hash {
            then: write_job(kind, buf),
        },
        queued_at: Instant::now(),
    }
}

/// Hash job whose request buffer is the job's own; `then` carries an empty buffer.
fn hash_job_buffer_in_job(kind: WriteKind, password: &[u8]) -> PasswordJob {
    let (buf, field) = request_buf(password);
    PasswordJob {
        origin: origin(9),
        buf,
        password: field,
        kind: PasswordKind::Hash {
            then: write_job(kind, Vec::new()),
        },
        queued_at: Instant::now(),
    }
}

// ---- gather rule ----

#[test]
fn a_full_batch_is_taken_at_once_without_waiting_for_the_window() {
    let queue = PasswordQueue::new(Duration::from_secs(60));
    for slot in 0..(MAX_LANES as u32 + 2) {
        queue.push(verify_job(slot, 1, PASSWORD));
    }
    let mut batch = Vec::new();
    let started = Instant::now();
    assert!(queue.take_batch(&mut batch));
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(batch.len(), MAX_LANES);
    assert_eq!(batch[0].origin.conn.slot, 0, "oldest first");
    assert_eq!(queue.len(), 2);
}

#[test]
fn a_lone_job_waits_for_the_window_and_not_much_longer() {
    let window = Duration::from_millis(80);
    let queue = PasswordQueue::new(window);
    let job = verify_job(0, 1, PASSWORD);
    let queued = job.queued_at;
    queue.push(job);
    let mut batch = Vec::new();
    assert!(queue.take_batch(&mut batch));
    let waited = queued.elapsed();
    assert!(waited >= window, "waited {waited:?}");
    assert!(
        waited < window + Duration::from_millis(500),
        "waited {waited:?}"
    );
    assert_eq!(batch.len(), 1);
}

#[test]
fn window_zero_takes_what_is_there() {
    let queue = PasswordQueue::new(Duration::ZERO);
    queue.push(verify_job(0, 1, PASSWORD));
    queue.push(verify_job(1, 1, PASSWORD));
    let mut batch = Vec::new();
    assert!(queue.take_batch(&mut batch));
    assert_eq!(batch.len(), 2);
}

#[test]
fn a_late_arrival_completes_the_batch_early() {
    let queue = PasswordQueue::new(Duration::from_secs(60));
    let taker = {
        let queue = queue.clone();
        std::thread::spawn(move || {
            let mut batch = Vec::new();
            queue.take_batch(&mut batch);
            batch.len()
        })
    };
    for slot in 0..MAX_LANES as u32 {
        std::thread::sleep(Duration::from_millis(5));
        queue.push(verify_job(slot, 1, PASSWORD));
    }
    assert_eq!(taker.join().unwrap(), MAX_LANES);
}

#[test]
fn close_releases_a_waiting_taker_once_drained() {
    let queue = PasswordQueue::new(Duration::ZERO);
    queue.close();
    assert!(!queue.take_batch(&mut Vec::new()));
}

// ---- end to end ----

#[test]
fn right_password_answers_200_with_a_token_that_verifies() {
    let rig = Rig::new(Duration::ZERO);
    rig.queue.push(verify_job(0, 42, PASSWORD));
    let (status, body) = rig.reply();
    assert_eq!(status, 200);
    let doc = json::parse(body.as_bytes()).unwrap();
    let user = doc.get("user").expect("user object");
    assert_eq!(
        user.get("email").and_then(Value::as_str),
        Some("ann@example.com")
    );
    assert_eq!(user.get("username").and_then(Value::as_str), Some("ann"));
    assert!(user.get("bio").is_some_and(Value::is_null));
    assert_eq!(user.get("image").and_then(Value::as_str), Some("i.png"));
    let token = user.get("token").and_then(Value::as_str).unwrap();
    assert_eq!(rig.jwt.verify(token.as_bytes(), unix_secs()), Ok(42));
}

#[test]
fn wrong_password_answers_401() {
    let rig = Rig::new(Duration::ZERO);
    rig.queue.push(verify_job(0, 1, b"password124"));
    let (status, body) = rig.reply();
    assert_eq!(status, 401);
    assert_eq!(body, r#"{"errors":{"body":["invalid credentials"]}}"#);
}

#[test]
fn malformed_stored_hash_answers_401_without_computing() {
    let rig = Rig::new(Duration::ZERO);
    let mut job = verify_job(0, 1, PASSWORD);
    job.kind = PasswordKind::Verify {
        user: user(1, [b'x'; 60]),
    };
    rig.queue.push(job);
    assert_eq!(rig.reply().0, 401);
}

#[test]
fn right_and_wrong_logins_in_one_batch_get_their_own_answers() {
    let rig = Rig::new(Duration::from_secs(60));
    for slot in 0..MAX_LANES as u32 {
        let password: &[u8] = if slot % 2 == 0 { PASSWORD } else { b"nope" };
        rig.queue.push(verify_job(slot, i64::from(slot), password));
    }
    let mut by_slot = [0u16; MAX_LANES];
    for _ in 0..MAX_LANES {
        let Event::Reply(r) = rig.next() else {
            panic!("reply expected")
        };
        by_slot[r.conn.slot as usize] = status_of(&r);
    }
    assert_eq!(by_slot, [200, 401, 200, 401, 200, 401]);
}

#[test]
fn keep_alive_false_closes_after_the_reply() {
    let rig = Rig::new(Duration::ZERO);
    let mut job = verify_job(0, 1, PASSWORD);
    job.origin.keep_alive = false;
    rig.queue.push(job);
    let Event::Reply(r) = rig.next() else {
        panic!("reply expected")
    };
    assert!(r.close);
    assert!(body_of(&r).starts_with(r#"{"user""#));
    assert!(
        std::str::from_utf8(&r.bytes[r.start..])
            .unwrap()
            .contains("Connection: close")
    );
}

fn expect_write(rig: &Rig) -> Box<WriteJob> {
    match rig.next() {
        Event::Write(job) => job,
        Event::Reply(r) => panic!("expected a write, got reply {}", status_of(&r)),
    }
}

#[test]
fn register_hash_goes_to_the_write_and_checks_out() {
    let rig = Rig::new(Duration::ZERO);
    rig.queue
        .push(hash_job_buffer_in_then(register_kind(), b"s3cret-pw"));
    let job = expect_write(&rig);
    let WriteKind::Register { password_hash, .. } = job.kind else {
        panic!("kind changed")
    };
    assert!(crate::bcrypt::verify(b"s3cret-pw", &password_hash));
    assert_eq!(
        crate::bcrypt::parse(&password_hash).unwrap().cost,
        BCRYPT_COST
    );
    assert_eq!(&job.buf[..4], b"junk", "request buffer arrived intact");
}

#[test]
fn the_request_buffer_is_moved_not_copied() {
    let rig = Rig::new(Duration::ZERO);
    let job = hash_job_buffer_in_job(register_kind(), b"s3cret-pw");
    let address = job.buf.as_ptr();
    rig.queue.push(job);
    let write = expect_write(&rig);
    assert_eq!(write.buf.as_ptr(), address, "same allocation");
    let job = hash_job_buffer_in_then(register_kind(), b"s3cret-pw");
    let PasswordKind::Hash { then } = &job.kind else {
        unreachable!()
    };
    let address = then.buf.as_ptr();
    rig.queue.push(job);
    assert_eq!(expect_write(&rig).buf.as_ptr(), address, "same allocation");
}

#[test]
fn update_user_gets_some_hash_and_other_fields_survive() {
    let rig = Rig::new(Duration::ZERO);
    let kind = WriteKind::UpdateUser {
        email: Some(Field::new(1..3)),
        username: None,
        password_hash: None,
        bio: None,
        image: None,
        token: Field::new(0..2),
    };
    rig.queue
        .push(hash_job_buffer_in_then(kind, b"new password"));
    let job = expect_write(&rig);
    let WriteKind::UpdateUser {
        email,
        password_hash,
        ..
    } = job.kind
    else {
        panic!("kind changed")
    };
    assert_eq!(email, Some(Field::new(1..3)));
    assert!(crate::bcrypt::verify(
        b"new password",
        &password_hash.expect("hash filled")
    ));
}

#[test]
fn two_hashes_get_different_salts() {
    let rig = Rig::new(Duration::ZERO);
    for _ in 0..2 {
        rig.queue
            .push(hash_job_buffer_in_then(register_kind(), b"same"));
    }
    let mut hashes = Vec::new();
    while hashes.len() < 2 {
        let WriteKind::Register { password_hash, .. } = expect_write(&rig).kind else {
            panic!()
        };
        hashes.push(password_hash);
    }
    assert_ne!(hashes[0][7..29], hashes[1][7..29]);
}

#[test]
fn a_hash_job_with_a_non_password_write_is_a_500() {
    let rig = Rig::new(Duration::ZERO);
    rig.queue.push(hash_job_buffer_in_then(
        WriteKind::Follow {
            username: Field::default(),
            follow: true,
        },
        b"x",
    ));
    assert_eq!(rig.reply().0, 500);
}

#[test]
fn passwords_beyond_72_bytes_are_truncated_by_bcrypt() {
    let rig = Rig::new(Duration::ZERO);
    let long = [b'a'; 80];
    rig.queue
        .push(hash_job_buffer_in_then(register_kind(), &long));
    let WriteKind::Register { password_hash, .. } = expect_write(&rig).kind else {
        panic!()
    };
    assert!(crate::bcrypt::verify(&long[..72], &password_hash));
}

#[test]
fn six_concurrent_logins_cost_about_one_batch() {
    let rig = Rig::new(Duration::from_secs(60));
    let started = Instant::now();
    for slot in 0..MAX_LANES as u32 {
        rig.queue.push(verify_job(slot, 1, PASSWORD));
    }
    for _ in 0..MAX_LANES {
        assert_eq!(rig.reply().0, 200);
    }
    let batch_time = started.elapsed();
    let single = time_single_login();
    eprintln!("6 logins together: {batch_time:?}; one login alone: {single:?}");
    assert!(
        batch_time < single * 4,
        "six together {batch_time:?} vs one {single:?}"
    );
}

// ---- measurements (cargo test --release-like: opt-level 2 in the test profile) ----

fn time_single_login() -> Duration {
    let rig = Rig::new(Duration::ZERO);
    let started = Instant::now();
    rig.queue.push(verify_job(0, 1, PASSWORD));
    assert_eq!(rig.reply().0, 200);
    started.elapsed()
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// Login latency at 1, 3 and 6 simultaneous jobs (window 0 so nothing waits) and hashes per second.
/// Run: `cargo test --lib password::tests::measure -- --ignored --nocapture`.
#[test]
#[ignore]
fn measure() {
    for n in [1u32, 3, 6] {
        let rig = Rig::new(Duration::ZERO);
        let mut best = Duration::MAX;
        for _ in 0..5 {
            let started = Instant::now();
            for slot in 0..n {
                rig.queue.push(verify_job(slot, 1, PASSWORD));
            }
            for _ in 0..n {
                assert_eq!(rig.reply().0, 200);
            }
            best = best.min(started.elapsed());
        }
        eprintln!("login latency with {n} simultaneous jobs: best of 5 {best:?}");
    }
    let rig = Rig::new(Duration::from_secs(60));
    let rounds = 10u32;
    let started = Instant::now();
    for round in 0..rounds {
        for slot in 0..MAX_LANES as u32 {
            rig.queue.push(verify_job(round * 10 + slot, 1, PASSWORD));
        }
        for _ in 0..MAX_LANES {
            rig.reply();
        }
    }
    let hashes = f64::from(rounds) * MAX_LANES as f64;
    eprintln!(
        "throughput with full batches: {:.1} hashes/s per thread",
        hashes / started.elapsed().as_secs_f64()
    );
}
