//! Bcrypt KDF background worker thread implementation.
//! Runs at SCHED_BATCH / nice 5 priority to ensure fast login turnarounds without starving Postgres or IO.
//! Batches verify jobs up to 6-wide (SIMD AVX) as soon as jobs are available, with ZERO artificial hold delay.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::rt::spsc::SpscQueue;
use crate::rt::thread::{is_pin_enabled, spawn_worker, wait_eventfd, SchedPolicy};
use crate::sec::bcrypt::{bcrypt_hash, bcrypt_verify_batch, VerifyItem};
use crate::sec::jwt::jwt_sign;
use crate::types::{Envelope, Job, KdfJob, Reply};

/// Computes the default number of KDF worker threads.
/// Controlled via env `KDF_THREADS`, defaulting to `(allowed_cpus / 2).max(1)` per R3/R7.
pub fn get_default_kdf_threads() -> usize {
    std::env::var("KDF_THREADS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| {
            let allowed = crate::rt::thread::get_allowed_cpus();
            (allowed.len() / 2).max(1)
        })
}

/// Spawns a single KDF worker thread with a specified worker index.
pub fn spawn_kdf_worker_indexed(
    worker_idx: usize,
    kdf_queues: Vec<Arc<SpscQueue<KdfJob, 512>>>,
    kdf_reply_queues: Vec<Arc<SpscQueue<Reply, 512>>>,
    // One queue per pg driver; this thread is the only producer of each (SPSC).
    pg_queues: Vec<Arc<SpscQueue<Envelope, 1024>>>,
    stop_signal: Arc<AtomicBool>,
) -> std::thread::JoinHandle<()> {
    let name = format!("kdf-worker-{}", worker_idx);
    spawn_worker(
        &name,
        None, // No hard CPU pin, allows Linux kernel to schedule across allowed cores
        SchedPolicy::Batch,
        move || {
            if is_pin_enabled() {
                unsafe {
                    libc::nice(5);
                }
            }

            let mut pending_verifies: Vec<KdfJob> = Vec::with_capacity(32);
            let mut overflow_pg: VecDeque<(usize, Envelope)> = VecDeque::new();
            let mut overflow_replies: VecDeque<(usize, Reply)> = VecDeque::new();
            const FULL_BATCH: usize = 6;

            while !stop_signal.load(Ordering::Relaxed) {
                // 1. Drain pending overflow queues first (strict FIFO preservation, never drop)
                if !overflow_pg.is_empty() {
                    let mut i = 0;
                    while i < overflow_pg.len() {
                        let pg_idx = overflow_pg[i].0;
                        if let Some(pg_q) = pg_queues.get(pg_idx) {
                            let item = overflow_pg.remove(i).unwrap();
                            match pg_q.push(item.1) {
                                Ok(()) => continue,
                                Err(env) => {
                                    overflow_pg.insert(i, (item.0, env));
                                    i += 1;
                                }
                            }
                        } else {
                            i += 1;
                        }
                    }
                }

                if !overflow_replies.is_empty() {
                    let mut i = 0;
                    while i < overflow_replies.len() {
                        let reactor_idx = overflow_replies[i].0;
                        if let Some(reply_q) = kdf_reply_queues.get(reactor_idx) {
                            let item = overflow_replies.remove(i).unwrap();
                            match reply_q.push(item.1) {
                                Ok(()) => continue,
                                Err(reply) => {
                                    overflow_replies.insert(i, (item.0, reply));
                                    i += 1;
                                }
                            }
                        } else {
                            i += 1;
                        }
                    }
                }

                // 2. Drain incoming jobs from all assigned input queues
                let mut found_any = false;
                for q in &kdf_queues {
                    while let Some(job) = q.pop() {
                        found_any = true;
                        match job {
                            KdfJob::Hash { password, mut then } => {
                                // Password hashing (signup/update): cost 10 and forward to PG
                                let hash_str = bcrypt_hash(&password, 10);
                                match &mut then.job {
                                    Job::Register { password_hash, .. } => {
                                        *password_hash = hash_str.into_boxed_str();
                                    }
                                    Job::UserUpdate { password_hash, .. } => {
                                        *password_hash = Some(hash_str.into_boxed_str());
                                    }
                                    _ => {}
                                }
                                // Forward to the pg driver for this connection via kdf's own SPSC queue
                                let pg_idx = then.conn.slot as usize % pg_queues.len().max(1);
                                if let Some(pg_q) = pg_queues.get(pg_idx) {
                                    if overflow_pg.is_empty() {
                                        if let Err(env) = pg_q.push(then) {
                                            overflow_pg.push_back((pg_idx, env));
                                        }
                                    } else {
                                        overflow_pg.push_back((pg_idx, then));
                                    }
                                }
                            }
                            verify_job @ KdfJob::Verify { .. } => {
                                pending_verifies.push(verify_job);
                            }
                        }
                    }
                }

                // 3. Process pending verifies IMMEDIATELY (ZERO hold delay; batch what's queued)
                while !pending_verifies.is_empty() {
                    let batch_size = pending_verifies.len().min(FULL_BATCH);
                    let batch: Vec<KdfJob> = pending_verifies.drain(..batch_size).collect();

                    // Prepare items for batch verify
                    let mut items = Vec::with_capacity(batch.len());
                    for job in &batch {
                        if let KdfJob::Verify { password, stored_hash, .. } = job {
                            items.push(VerifyItem {
                                password: password.as_bytes(),
                                stored_hash: stored_hash.as_ref(),
                            });
                        }
                    }

                    let results = bcrypt_verify_batch(&items);

                    // Send replies
                    for (job, ok) in batch.into_iter().zip(results) {
                        if let KdfJob::Verify {
                            env_conn,
                            keepalive,
                            user_id,
                            username,
                            email,
                            bio,
                            image,
                            ..
                        } = job
                        {
                            let reply = if ok {
                                let token = jwt_sign(user_id);
                                let mut body_buf = Vec::with_capacity(256);
                                crate::api::render_user(
                                    &mut body_buf,
                                    &crate::api::UserRow {
                                        email: &email,
                                        token: &token,
                                        username: &username,
                                        bio: bio.as_deref(),
                                        image: image.as_deref(),
                                    },
                                );
                                let resp = crate::api::frame_response(200, "OK", &body_buf, keepalive);
                                Reply {
                                    conn: env_conn,
                                    bytes: resp,
                                    close: !keepalive,
                                }
                            } else {
                                Reply {
                                    conn: env_conn,
                                    bytes: crate::api::reply_401("email or password is invalid", keepalive),
                                    close: !keepalive,
                                }
                            };

                            let reactor_idx = env_conn.reactor as usize;
                            if let Some(reply_q) = kdf_reply_queues.get(reactor_idx) {
                                if overflow_replies.is_empty() {
                                    if let Err(rep) = reply_q.push(reply) {
                                        overflow_replies.push_back((reactor_idx, rep));
                                    }
                                } else {
                                    overflow_replies.push_back((reactor_idx, reply));
                                }
                            }
                        }
                    }
                }

                // 4. Sleep or yield
                let has_overflow = !overflow_pg.is_empty() || !overflow_replies.is_empty();
                if !found_any && !has_overflow {
                    let wake_fd = kdf_queues.first().map(|q| q.event_fd).unwrap_or(-1);
                    if wake_fd >= 0 {
                        for q in &kdf_queues {
                            q.mark_sleeping();
                        }
                        if kdf_queues.iter().all(|q| q.is_empty()) {
                            wait_eventfd(wake_fd, 5);
                        }
                        for q in &kdf_queues {
                            q.mark_awake();
                        }
                    } else {
                        std::thread::yield_now();
                    }
                } else if has_overflow {
                    std::thread::yield_now();
                }
            }
        },
    )
    .expect("spawn kdf worker")
}

/// Backwards-compatible wrapper spawning worker 0.
pub fn spawn_kdf_worker(
    kdf_queues: Vec<Arc<SpscQueue<KdfJob, 512>>>,
    kdf_reply_queues: Vec<Arc<SpscQueue<Reply, 512>>>,
    pg_queues: Vec<Arc<SpscQueue<Envelope, 1024>>>,
    stop_signal: Arc<AtomicBool>,
) -> std::thread::JoinHandle<()> {
    spawn_kdf_worker_indexed(0, kdf_queues, kdf_reply_queues, pg_queues, stop_signal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use crate::types::ConnRef;

    #[test]
    fn test_kdf_worker_reply_ordering_per_connection() {
        let stop = Arc::new(AtomicBool::new(false));
        let in_q = Arc::new(SpscQueue::<KdfJob, 512>::new(-1));
        let reply_q = Arc::new(SpscQueue::<Reply, 512>::new(-1));
        let pg_q = Arc::new(SpscQueue::<Envelope, 1024>::new(-1));

        let handle = spawn_kdf_worker_indexed(
            99,
            vec![in_q.clone()],
            vec![reply_q.clone()],
            vec![pg_q.clone()],
            stop.clone(),
        );

        let conn = ConnRef { reactor: 0, slot: 10, gen: 1 };
        // Create 6 different known hashes
        let test_passwords = ["pass1", "pass2", "pass3", "pass4", "pass5", "pass6"];
        let mut hashes = Vec::new();
        for pw in &test_passwords {
            hashes.push(bcrypt_hash(pw, 4)); // cost 4 for fast test execution
        }

        // Submit in sequence
        for (i, pw) in test_passwords.iter().enumerate() {
            in_q.push(KdfJob::Verify {
                env_conn: conn,
                keepalive: true,
                user_id: (i + 1) as i64,
                username: format!("user{}", i).into_boxed_str(),
                email: format!("user{}@example.com", i).into_boxed_str(),
                bio: None,
                image: None,
                password: pw.to_string().into_boxed_str(),
                stored_hash: hashes[i].clone().into_boxed_str(),
            }).expect("push job");
        }

        // Collect replies and verify strict FIFO ordering
        let mut received = Vec::new();
        let start = std::time::Instant::now();
        while received.len() < test_passwords.len() && start.elapsed() < Duration::from_secs(5) {
            if let Some(reply) = reply_q.pop() {
                assert_eq!(reply.conn, conn);
                let body = String::from_utf8(reply.bytes).expect("utf8");
                assert!(body.starts_with("HTTP/1.1 200 OK"));
                received.push(body);
            } else {
                std::thread::sleep(Duration::from_millis(5));
            }
        }

        assert_eq!(received.len(), test_passwords.len());
        for (i, body) in received.iter().enumerate() {
            let expected_user = format!("user{}", i);
            assert!(body.contains(&expected_user), "Reply {} must be for {}", i, expected_user);
        }

        stop.store(true, Ordering::Relaxed);
        handle.join().expect("join");
    }

    #[test]
    fn test_kdf_worker_no_drop_when_queues_full() {
        let stop = Arc::new(AtomicBool::new(false));
        let in_q = Arc::new(SpscQueue::<KdfJob, 512>::new(-1));
        let reply_q = Arc::new(SpscQueue::<Reply, 512>::new(-1));
        let pg_q = Arc::new(SpscQueue::<Envelope, 1024>::new(-1));

        // Pre-fill reply queue to capacity (512)
        let dummy_conn = ConnRef { reactor: 0, slot: 1, gen: 1 };
        for _ in 0..512 {
            reply_q.push(Reply {
                conn: dummy_conn,
                bytes: b"HTTP/1.1 200 OK\r\n\r\n".to_vec(),
                close: false,
            }).expect("pre-fill");
        }
        assert!(reply_q.push(Reply {
            conn: dummy_conn,
            bytes: b"".to_vec(),
            close: false,
        }).is_err(), "Queue must be full");

        let handle = spawn_kdf_worker_indexed(
            98,
            vec![in_q.clone()],
            vec![reply_q.clone()],
            vec![pg_q.clone()],
            stop.clone(),
        );

        let hash = bcrypt_hash("my-secret", 4);
        let test_conn = ConnRef { reactor: 0, slot: 99, gen: 1 };
        in_q.push(KdfJob::Verify {
            env_conn: test_conn,
            keepalive: true,
            user_id: 12345,
            username: "overflow_user".to_string().into_boxed_str(),
            email: "overflow@example.com".to_string().into_boxed_str(),
            bio: None,
            image: None,
            password: "my-secret".to_string().into_boxed_str(),
            stored_hash: hash.into_boxed_str(),
        }).expect("push job");

        // Give worker time to process and encounter the full reply queue (placing in overflow)
        std::thread::sleep(Duration::from_millis(50));

        // Drain 1 item from reply queue to make space
        let first = reply_q.pop().expect("pop prefilled");
        assert_eq!(first.conn, dummy_conn);

        // Worker should now drain its overflow queue and deliver the test reply
        let mut got_test_reply = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(2) {
            if let Some(r) = reply_q.pop() {
                if r.conn == test_conn {
                    got_test_reply = true;
                    let body = String::from_utf8(r.bytes).unwrap();
                    assert!(body.starts_with("HTTP/1.1 200 OK"));
                    assert!(body.contains("overflow_user"));
                    break;
                }
            } else {
                std::thread::sleep(Duration::from_millis(5));
            }
        }

        assert!(got_test_reply, "Overflow reply must be delivered without being dropped");

        stop.store(true, Ordering::Relaxed);
        handle.join().expect("join");
    }

    #[test]
    fn test_kdf_worker_seed_hash_and_hash_roundtrip() {
        let stop = Arc::new(AtomicBool::new(false));
        let in_q = Arc::new(SpscQueue::<KdfJob, 512>::new(-1));
        let reply_q = Arc::new(SpscQueue::<Reply, 512>::new(-1));
        let pg_q = Arc::new(SpscQueue::<Envelope, 1024>::new(-1));

        let handle = spawn_kdf_worker_indexed(
            97,
            vec![in_q.clone()],
            vec![reply_q.clone()],
            vec![pg_q.clone()],
            stop.clone(),
        );

        let conn = ConnRef { reactor: 0, slot: 5, gen: 1 };

        // 1. Verify seed hash $2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq with password123
        let seed_h = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
        in_q.push(KdfJob::Verify {
            env_conn: conn,
            keepalive: true,
            user_id: 1,
            username: "seeduser".to_string().into_boxed_str(),
            email: "seed@example.com".to_string().into_boxed_str(),
            bio: None,
            image: None,
            password: "password123".to_string().into_boxed_str(),
            stored_hash: seed_h.to_string().into_boxed_str(),
        }).expect("push seed verify");

        // Wait for reply
        let start = std::time::Instant::now();
        let mut got_seed_reply = false;
        while start.elapsed() < Duration::from_secs(5) {
            if let Some(r) = reply_q.pop() {
                let body = String::from_utf8(r.bytes).unwrap();
                assert!(body.starts_with("HTTP/1.1 200 OK"), "Seed hash must verify 200 OK: {}", body);
                assert!(body.contains("seeduser"));
                got_seed_reply = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(got_seed_reply);

        // 2. Verify wrong password gives 401
        in_q.push(KdfJob::Verify {
            env_conn: conn,
            keepalive: true,
            user_id: 1,
            username: "seeduser".to_string().into_boxed_str(),
            email: "seed@example.com".to_string().into_boxed_str(),
            bio: None,
            image: None,
            password: "wrong-password".to_string().into_boxed_str(),
            stored_hash: seed_h.to_string().into_boxed_str(),
        }).expect("push bad verify");

        let start = std::time::Instant::now();
        let mut got_bad_reply = false;
        while start.elapsed() < Duration::from_secs(5) {
            if let Some(r) = reply_q.pop() {
                let body = String::from_utf8(r.bytes).unwrap();
                assert!(body.starts_with("HTTP/1.1 401 Unauthorized"), "Wrong password must be 401: {}", body);
                got_bad_reply = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(got_bad_reply);

        // 3. Test KdfJob::Hash roundtrip
        let register_env = Envelope {
            conn,
            viewer: 0,
            token: None,
            keepalive: true,
            job: Job::Register {
                username: "newuser".to_string().into_boxed_str(),
                email: "new@example.com".to_string().into_boxed_str(),
                password_hash: "".to_string().into_boxed_str(),
            },
        };

        in_q.push(KdfJob::Hash {
            password: "newpassword123".to_string().into_boxed_str(),
            then: register_env,
        }).expect("push hash job");

        // Check forwarded envelope in pg_q
        let start = std::time::Instant::now();
        let mut hashed_str = String::new();
        while start.elapsed() < Duration::from_secs(5) {
            if let Some(env) = pg_q.pop() {
                if let Job::Register { password_hash, .. } = env.job {
                    assert!(password_hash.starts_with("$2b$10$"), "Must be cost 10 $2b$: {}", password_hash);
                    hashed_str = password_hash.to_string();
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!hashed_str.is_empty(), "Hashed envelope must be forwarded to PG queue");

        stop.store(true, Ordering::Relaxed);
        handle.join().expect("join");
    }
}
