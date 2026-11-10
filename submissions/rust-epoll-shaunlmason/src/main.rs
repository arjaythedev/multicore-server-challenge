mod api;
mod bcrypt;
mod bf_consts;
mod db;
mod http;
mod json;
mod jwt;
mod pg;
mod queue;
mod render;
mod reply;
mod sql;

use std::time::Duration;

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn env_or<T: std::str::FromStr>(k: &str, d: T) -> T {
    std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d)
}

fn spawn(name: &str, f: impl FnOnce() + Send + 'static) -> std::thread::JoinHandle<()> {
    std::thread::Builder::new().name(name.into()).spawn(f).expect("spawn")
}

fn main() {
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
    let secret = std::env::var("JWT_SECRET").expect("JWT_SECRET");
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port: u16 = env_or("PORT", 80);
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(8);
    let io_threads: usize = env_or("IO_THREADS", (cpus / 4).max(1));
    // Fewer, larger read batches cost Postgres less per request: measured 4 lanes beat 8 on 8 cores (cores/1k req/s 0.330 vs 0.351).
    let read_lanes: usize = env_or("READ_LANES", (cpus / 2).max(2));
    let bcrypt_threads: usize = env_or("BCRYPT_THREADS", 2);

    let keys: &'static jwt::Keys = Box::leak(Box::new(jwt::Keys::new(secret.as_bytes())));
    db::init(db::Settings {
        cfg: pg::Config::parse(&url).expect("DATABASE_URL must be postgres://user:password@host:port/db"),
        keys,
        read_window: Duration::from_micros(env_or("READ_WINDOW_US", 20_000)),
        read_max: env_or("READ_MAX", 4096),
        write_max: env_or("WRITE_MAX", 256),
        bcrypt_window: Duration::from_millis(env_or("BCRYPT_WINDOW_MS", 400)),
    });
    // Fail fast if Postgres is unreachable or a statement doesn't prepare.
    if let Err(e) = db::connect(&[sql::phase_a(), sql::phase_b(), sql::writes()].concat()) {
        panic!("postgres: {e}");
    }

    let efds = reply::init(io_threads);
    for _ in 0..read_lanes {
        spawn("read", db::read_lane);
    }
    spawn("write", db::write_lane);
    for i in 0..bcrypt_threads {
        spawn("bcrypt", move || db::bcrypt_worker(i));
    }
    let handles: Vec<_> = efds
        .into_iter()
        .enumerate()
        .map(|(t, efd)| {
            let lfd = http::listener(&host, port).expect("listen");
            let server = http::Server::new(t as u16, lfd, efd, keys).expect("epoll");
            spawn("io", move || server.run())
        })
        .collect();
    eprintln!("listening on {host}:{port}: {io_threads} io threads, {read_lanes} read lanes, {bcrypt_threads} bcrypt threads");
    for h in handles {
        let _ = h.join();
    }
}

#[cfg(test)]
mod pg_live {
    use crate::pg::*;

    /// Needs a local Postgres with the dev seed: PG_TEST_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev
    #[test]
    #[ignore]
    fn pipeline_roundtrip() {
        let url = std::env::var("PG_TEST_URL").unwrap();
        let mut c = Conn::connect(&Config::parse(&url).unwrap()).unwrap();
        c.prepare(&[("ids", "SELECT r.k, u.id, u.username, u.bio FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN users u ON u.id = r.id", &[INT8_ARRAY]),
                    ("tags", "SELECT ARRAY(SELECT name FROM tags ORDER BY name)", &[])]).unwrap();
        let ids = Array::i64s([1, 2, 3]);
        c.out.exec("ids", &[Param::Raw(&ids)]);
        c.out.exec("tags", &[]);
        let p = c.run(2).unwrap();
        assert!(p.res.iter().all(|r| r.error.is_none()));
        assert_eq!(p.res[0].len(), 3);
        for row in p.res[0].rows() {
            assert!(p.i64(row[1]) >= 1 && !p.bytes(row[2]).is_empty());
        }
        let tags: Vec<&[u8]> = array_elems(p.bytes(p.res[1].row(0)[0])).collect();
        assert_eq!(tags.len(), 200);
        // a second pipeline on the same connection, with an error in the middle
        c.out.exec("ids", &[Param::Raw(&ids)]);
        c.out.exec("nope", &[]);
        c.out.exec("tags", &[]);
        let p = c.run(3).unwrap();
        assert!(p.res[0].error.is_none() && p.res[1].error.is_some() && p.res[2].error.is_some());
        // and it still works after the error
        c.out.exec("tags", &[]);
        let p = c.run(1).unwrap();
        assert!(p.res[0].error.is_none());
    }
}

