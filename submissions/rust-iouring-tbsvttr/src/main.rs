mod bcrypt;
mod blowfish;
mod buf;
mod json;
mod jwt;
mod pg;
mod server;
mod sys;

use std::net::SocketAddrV4;
use std::sync::{Arc, Mutex};

use crate::bcrypt::{BCRYPT_LANES, calibrate_lanes};
use crate::jwt::JwtKey;
use crate::pg::DbUrl;
use crate::server::{BcryptPool, DbEngine, DbInbox, Worker, WorkerInbox, build_statements};
use crate::sys::{
    open_listener, raise_nofile_limit, resolve_ipv4, set_sched_batch, unshare_files, usable_cpus,
};

fn env_str(name: &str, default: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.to_string())
}

fn env_i64(name: &str, default: i64) -> i64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(default)
}

fn create_eventfd() -> i32 {
    #[cfg(target_os = "linux")]
    unsafe {
        crate::sys::eventfd(0, crate::sys::EFD_NONBLOCK | crate::sys::EFD_CLOEXEC)
    }
    #[cfg(not(target_os = "linux"))]
    {
        -1
    }
}

fn main() {
    unsafe {
        crate::sys::signal(crate::sys::SIGPIPE, crate::sys::SIG_IGN);
    }
    raise_nofile_limit();
    if env_i64("SCHED_BATCH", 1) != 0 {
        set_sched_batch(0);
    }

    let db_url_str = match std::env::var("DATABASE_URL") {
        Ok(v) if !v.is_empty() => v,
        _ => {
            eprintln!("DATABASE_URL and JWT_SECRET are required");
            std::process::exit(1);
        }
    };
    let jwt_secret = match std::env::var("JWT_SECRET") {
        Ok(v) if !v.is_empty() => v,
        _ => {
            eprintln!("DATABASE_URL and JWT_SECRET are required");
            std::process::exit(1);
        }
    };

    let host = env_str("HOST", "127.0.0.1");
    let port: u16 = env_i64("PORT", 3000) as u16;
    let extra_port_str = env_str("EXTRA_PORT", "");
    let extra_port: Option<u16> = if extra_port_str.is_empty() {
        None
    } else {
        extra_port_str.parse::<u16>().ok()
    };

    let batch_us = env_i64("BATCH_US", 2000).max(0) as u32;
    let quickack = env_i64("QUICKACK", 0) != 0;
    let quickack_ms = env_i64("QUICKACK_MS", 25);
    let defer_accept = env_i64("DEFER_ACCEPT", 1) as i32;

    let cpus = usable_cpus().max(1);
    let mut workers = env_i64("WORKERS", 0) as usize;
    if workers < 1 {
        workers = (cpus / 2).max(1);
    }
    workers = workers.min(64);

    let pool_size = env_i64("DB_POOL", 48).clamp(1, 95) as usize;
    let batch_inflight = env_i64("BATCH_INFLIGHT", 3).max(1) as i32;
    let batch_ms = env_i64("BATCH_MS", 20).max(0);
    let batch_slow_ms = env_i64("BATCH_SLOW_MS", 100).max(0);
    let batch_max = env_i64("BATCH_MAX", 4000).max(1) as usize;

    let mut helpers = env_i64("BCRYPT_HELPERS", 0) as usize;
    if helpers < 1 {
        helpers = cpus;
    }
    let mut lanes = env_i64("BCRYPT_LANES", 0) as usize;
    if !(1..=BCRYPT_LANES).contains(&lanes) {
        lanes = calibrate_lanes();
    }
    let wait_ms = env_i64("BCRYPT_WAIT_MS", 150).max(0);

    let mut worker_inboxes = Vec::with_capacity(workers);
    for _ in 0..workers {
        worker_inboxes.push(Arc::new(WorkerInbox {
            event_fd: create_eventfd(),
            queue: Mutex::new(Vec::with_capacity(512)),
        }));
    }
    let worker_inboxes = Arc::new(worker_inboxes);

    let db_inbox = Arc::new(DbInbox {
        event_fd: create_eventfd(),
        queue: Mutex::new(Vec::with_capacity(2048)),
    });

    let bcrypt_pool = BcryptPool::start(helpers, lanes, wait_ms, Arc::clone(&worker_inboxes));
    println!("conduit: {helpers} bcrypt helpers, {lanes} lanes each");

    let jwt_key = JwtKey::new(jwt_secret.as_bytes());
    let db_url = DbUrl::parse(&db_url_str);
    let statements = build_statements();

    // Open SO_REUSEPORT listeners for each worker
    let bind_ip = resolve_ipv4(&host, port);
    let bind_addr = SocketAddrV4::new(bind_ip, port);
    let extra_addr = extra_port.map(|ep| SocketAddrV4::new(resolve_ipv4(&host, ep), ep));
    let mut listeners = Vec::with_capacity(workers);
    for _ in 0..workers {
        let fd_a = open_listener(bind_addr, defer_accept, !quickack).unwrap_or_else(|e| {
            eprintln!("conduit: listen {host}:{port} failed: {e}");
            std::process::exit(1);
        });
        let fd_b = if let Some(ea) = extra_addr {
            open_listener(ea, defer_accept, !quickack).unwrap_or_else(|e| {
                eprintln!("conduit: listen {ea} failed: {e}");
                std::process::exit(1);
            })
        } else {
            -1
        };
        listeners.push((fd_a, fd_b));
    }

    println!("conduit: {workers} workers, a database coordinator with {pool_size} Postgres connections");

    // Spawn worker threads
    for (wid, (fd_a, fd_b)) in listeners.into_iter().enumerate() {
        let w_inbox = Arc::clone(&worker_inboxes[wid]);
        let d_inbox = Arc::clone(&db_inbox);
        let b_pool = Arc::clone(&bcrypt_pool);
        std::thread::spawn(move || {
            unshare_files();
            set_sched_batch(5);
            let mut worker = Worker::new(
                wid,
                fd_a,
                fd_b,
                jwt_key,
                quickack_ms,
                batch_us,
                w_inbox,
                d_inbox,
                b_pool,
            );
            #[cfg(target_os = "linux")]
            worker.run();
            #[cfg(not(target_os = "linux"))]
            let _ = &mut worker;
        });
    }

    // Run database coordinator on the main thread
    let mut db_engine = DbEngine::new(
        db_url,
        statements,
        jwt_key,
        pool_size,
        batch_inflight,
        batch_ms,
        batch_slow_ms,
        batch_max,
        batch_us,
        db_inbox,
        worker_inboxes,
    );
    #[cfg(target_os = "linux")]
    db_engine.run();
    #[cfg(not(target_os = "linux"))]
    let _ = &mut db_engine;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bcrypt::{BcryptJob, format as bc_format, parse as bc_parse, run as bc_run};
    use crate::buf::{put_int, put_json_string, put_timestamp};
    use crate::jwt::{ct_eq, parse_id};
    use crate::server::{IdTable, N_STATEMENTS, build_statements, text_ok, url_decode};

    #[test]
    fn test_buf_formatters() {
        let mut b = Vec::new();
        put_int(&mut b, 0);
        assert_eq!(&b, b"0");
        b.clear();
        put_int(&mut b, -1234567890);
        assert_eq!(&b, b"-1234567890");

        b.clear();
        put_json_string(&mut b, b"hello \"world\"\n\t\\/");
        assert_eq!(&b, br#""hello \"world\"\n\t\\/""#);

        // 2000-01-01T00:00:00.000Z is 0 us in Postgres epoch
        b.clear();
        put_timestamp(&mut b, 0);
        assert_eq!(std::str::from_utf8(&b).unwrap(), "\"2000-01-01T00:00:00.000Z\"");

        // 2025-04-01T12:00:00.000Z -> days since 2000-01-01 = 9222, seconds = 9222*86400 + 43200 = 796824000
        b.clear();
        put_timestamp(&mut b, 796_824_000_000_000);
        assert_eq!(std::str::from_utf8(&b).unwrap(), "\"2025-04-01T12:00:00.000Z\"");
    }

    #[test]
    fn test_json_parser() {
        let body = br#"{"user":{"username":"alice","email":"a@b.c","bio":null},"extra":[1,true,"x"]}"#;
        assert!(json::valid(body));
        let obj = json::body_object(body, b"user").unwrap();
        let mut out = Vec::new();
        assert!(json::required(obj, b"username", &mut out));
        assert_eq!(&out, b"alice");
        assert_eq!(json::obj_field(obj, b"bio", &mut out), 0);
        assert_eq!(json::obj_field(obj, b"missing", &mut out), 0);
    }

    #[test]
    fn test_jwt_sign_and_verify() {
        let key = JwtKey::new(b"multicore-server-challenge");
        let mut tok = Vec::new();
        let now = 1_750_000_000;
        key.sign(42, now, &mut tok);
        assert_eq!(key.verify(&tok, now + 100), 42);
        assert_eq!(key.verify(&tok, now + 30 * 86400 + 1), -1); // expired
        let wrong_key = JwtKey::new(b"wrong-secret");
        assert_eq!(wrong_key.verify(&tok, now + 100), -1);
        assert_eq!(parse_id(b"12345"), 12345);
        assert_eq!(parse_id(b"0"), -1);
    }

    #[test]
    fn test_bcrypt_multi_lane() {
        // Exact seeded password and hash from bench/seed/seed.go
        let seed_hash = b"$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
        let seed_pw = b"password123";
        let mut seed_job = BcryptJob::default();
        seed_job.password[..seed_pw.len()].copy_from_slice(seed_pw);
        seed_job.password_len = seed_pw.len();
        let mut seed_want = [0u8; 23];
        assert!(bc_parse(seed_hash, &mut seed_job, &mut seed_want));
        let mut seed_jobs = [seed_job];
        bc_run(&mut seed_jobs);
        assert!(
            ct_eq(&seed_jobs[0].digest, &seed_want),
            "failed to verify seeded bcrypt hash!"
        );

        let mut job = BcryptJob::default();
        job.cost = 4;
        job.password[..6].copy_from_slice(b"secret");
        job.password_len = 6;
        job.salt.copy_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
        let mut jobs = [job; 2];
        bc_run(&mut jobs);
        assert_eq!(jobs[0].digest, jobs[1].digest);

        let mut formatted = [0u8; 60];
        bc_format(&jobs[0], &mut formatted);

        let mut parsed_job = BcryptJob::default();
        parsed_job.password[..6].copy_from_slice(b"secret");
        parsed_job.password_len = 6;
        let mut want = [0u8; 23];
        assert!(bc_parse(&formatted, &mut parsed_job, &mut want));
        let mut verify_jobs = [parsed_job];
        bc_run(&mut verify_jobs);
        assert!(ct_eq(&verify_jobs[0].digest, &want));
    }

    #[test]
    fn test_statements_and_helpers() {
        let stmts = build_statements();
        assert_eq!(stmts.len(), N_STATEMENTS);
        for (i, sql) in stmts.iter().enumerate() {
            assert!(!sql.is_empty(), "statement {i} is empty");
        }

        let mut tbl = IdTable::<u32>::new();
        tbl.reset(10);
        tbl.put(100, 7);
        tbl.put(200, 9);
        assert_eq!(tbl.get(100), Some(7));
        assert_eq!(tbl.get(200), Some(9));
        assert_eq!(tbl.get(300), None);

        let mut dec = Vec::new();
        url_decode(b"hello+world%21", true, &mut dec);
        assert_eq!(&dec, b"hello world!");
        assert!(text_ok(b"valid utf8"));
        assert!(!text_ok(b"has\0nul"));
    }

    #[test]
    fn test_pages_and_comments_batch_assembly() {
        use crate::pg::{length_slot, put32, put64, set32};
        use crate::server::{DbTask, Job, WorkerMsg};

        fn push_col_null(row: &mut Vec<u8>) {
            put32(row, -1);
        }
        fn push_col_i64(row: &mut Vec<u8>, v: i64) {
            put32(row, 8);
            put64(row, v);
        }
        fn push_col_text(row: &mut Vec<u8>, s: &[u8]) {
            put32(row, s.len() as i32);
            row.extend_from_slice(s);
        }
        fn push_col_i64_array(row: &mut Vec<u8>, vals: &[i64]) {
            let at = length_slot(row);
            put32(row, 1); // 1D
            put32(row, 0); // no nulls
            put32(row, 20); // INT8 OID
            put32(row, vals.len() as i32);
            put32(row, 1); // lbound
            for &v in vals {
                put32(row, 8);
                put64(row, v);
            }
            let len = (row.len() - at - 4) as i32;
            set32(row, at, len);
        }
        fn wrap_datarow(msg: &mut Vec<u8>, ncols: u16, build: impl FnOnce(&mut Vec<u8>)) {
            msg.push(b'D');
            let at = length_slot(msg);
            msg.extend_from_slice(&ncols.to_be_bytes());
            build(msg);
            let len = (msg.len() - at) as i32;
            set32(msg, at, len);
        }

        let mut m = Vec::new();
        // k = -2: tag id=10, name="rust", rank=2; tag id=11, name="async", rank=1
        for &(tid, rank, name) in &[(10i64, 2i64, &b"rust"[..]), (11i64, 1i64, &b"async"[..])] {
            wrap_datarow(&mut m, 18, |r| {
                push_col_i64(r, -2);
                push_col_i64(r, rank);
                for _ in 0..3 {
                    push_col_null(r);
                }
                push_col_i64(r, tid);
                push_col_text(r, name);
                for _ in 0..11 {
                    push_col_null(r);
                }
            });
        }
        // k = -1: author id=7, username="alice", bio="hacker", image=NULL
        wrap_datarow(&mut m, 18, |r| {
            push_col_i64(r, -1);
            for _ in 0..4 {
                push_col_null(r);
            }
            push_col_i64(r, 7);
            for _ in 0..9 {
                push_col_null(r);
            }
            push_col_text(r, b"alice");
            push_col_text(r, b"hacker");
            push_col_null(r);
        });
        // k = 0: article id=99, slug="hello-99", title="Hello", desc="Desc", body="Body",
        // created_at=0, updated_at=0, tag_ids=[10, 11], fav_count=5, author_id=7
        wrap_datarow(&mut m, 18, |r| {
            push_col_i64(r, 0);
            for _ in 0..4 {
                push_col_null(r);
            }
            push_col_i64(r, 99);
            push_col_text(r, b"hello-99");
            push_col_text(r, b"Hello");
            push_col_text(r, b"Desc");
            push_col_text(r, b"Body");
            push_col_i64(r, 0);
            push_col_i64(r, 0);
            push_col_i64_array(r, &[10, 11]);
            push_col_i64(r, 5);
            push_col_i64(r, 7);
            for _ in 0..3 {
                push_col_null(r);
            }
        });
        // k = 1: list request (count=1, ids=[99], favs=[99], fols=[])
        wrap_datarow(&mut m, 18, |r| {
            push_col_i64(r, 1);
            push_col_i64(r, 1);
            push_col_i64_array(r, &[99]);
            push_col_i64_array(r, &[99]);
            push_col_i64_array(r, &[]);
            for _ in 0..13 {
                push_col_null(r);
            }
        });
        // k = 2: single article request (count=NULL, ids=[99], favs=[], fols=[7])
        wrap_datarow(&mut m, 18, |r| {
            push_col_i64(r, 2);
            push_col_null(r);
            push_col_i64_array(r, &[99]);
            push_col_i64_array(r, &[]);
            push_col_i64_array(r, &[7]);
            for _ in 0..13 {
                push_col_null(r);
            }
        });

        let w_inbox = Arc::new(WorkerInbox {
            event_fd: -1,
            queue: Mutex::new(Vec::new()),
        });
        let workers = Arc::new(vec![Arc::clone(&w_inbox)]);
        let db_inbox = Arc::new(DbInbox {
            event_fd: -1,
            queue: Mutex::new(Vec::new()),
        });
        let mut engine = DbEngine::new(
            DbUrl::parse("postgres://conduit:conduit@127.0.0.1:5432/conduit"),
            build_statements(),
            JwtKey::new(b"secret"),
            1,
            3,
            20,
            100,
            4000,
            0,
            db_inbox,
            workers,
        );

        let tasks = vec![
            DbTask {
                worker_id: 0,
                client_tag: 101,
                job: Job::ListGlobal,
                close_after: false,
                viewer: 1,
                nparams: 0,
                params: Vec::new(),
                token: Vec::new(),
            },
            DbTask {
                worker_id: 0,
                client_tag: 102,
                job: Job::Article,
                close_after: false,
                viewer: 1,
                nparams: 0,
                params: Vec::new(),
                token: Vec::new(),
            },
        ];

        engine.test_pages_finish(&tasks, &m);
        let msgs = w_inbox.queue.lock().unwrap();
        assert_eq!(msgs.len(), 2);

        if let WorkerMsg::Http { response, .. } = &msgs[0] {
            let s = std::str::from_utf8(response).unwrap();
            assert!(s.ends_with(
                r#"{"articles":[{"slug":"hello-99","title":"Hello","description":"Desc","createdAt":"2000-01-01T00:00:00.000Z","updatedAt":"2000-01-01T00:00:00.000Z","tagList":["async","rust"],"favoritesCount":5,"favorited":true,"author":{"username":"alice","bio":"hacker","image":null,"following":false}}],"articlesCount":1}"#
            ), "unexpected list response: {s}");
        } else {
            panic!("expected Http response");
        }

        if let WorkerMsg::Http { response, .. } = &msgs[1] {
            let s = std::str::from_utf8(response).unwrap();
            assert!(s.ends_with(
                r#"{"article":{"slug":"hello-99","title":"Hello","description":"Desc","body":"Body","createdAt":"2000-01-01T00:00:00.000Z","updatedAt":"2000-01-01T00:00:00.000Z","tagList":["async","rust"],"favoritesCount":5,"favorited":false,"author":{"username":"alice","bio":"hacker","image":null,"following":true}}}"#
            ), "unexpected article response: {s}");
        } else {
            panic!("expected Http response");
        }
    }
}
