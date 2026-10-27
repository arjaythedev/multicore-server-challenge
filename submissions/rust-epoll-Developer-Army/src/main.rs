mod api;
mod bcrypt;
mod bf_consts;
mod db;
mod http;
mod json;
mod jwt;
mod pg;
mod queue;
mod reply;
mod sql;

use std::time::Duration;

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn env_or<T: std::str::FromStr>(k: &str, d: T) -> T {
    std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d)
}

fn elevate_nofile_limit() {
    unsafe {
        let mut rlim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rlim) == 0 {
            // Elevate to maximum allowable limit up to 1,048,576
            let target = rlim.rlim_max.min(1_048_576);
            if rlim.rlim_cur < target {
                rlim.rlim_cur = target;
                let _ = libc::setrlimit(libc::RLIMIT_NOFILE, &rlim);
            }
        }
    }
}

fn main() {
    elevate_nofile_limit();

    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
    let secret = std::env::var("JWT_SECRET").expect("JWT_SECRET");
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port: u16 = env_or("PORT", 80);
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(8);

    // Optimized thread layout for 400K+ concurrent connections on 8 cores:
    // 4 IO threads for network polling + 16 read lanes + 2 write lanes + 3 bcrypt workers
    let io_threads: usize = env_or("IO_THREADS", (cpus / 2).max(2));
    let read_lanes: usize = env_or("READ_LANES", 16);
    let write_lanes: usize = env_or("WRITE_LANES", 2);
    let bcrypt_threads: usize = env_or("BCRYPT_THREADS", 3);

    let keys: &'static jwt::Keys = Box::leak(Box::new(jwt::Keys::new(secret.as_bytes())));
    let settings: &'static db::Settings = Box::leak(Box::new(db::Settings {
        cfg: pg::Config::parse(&url).expect("DATABASE_URL must be postgres://user:password@host:port/db"),
        keys,
        read_batch: env_or("READ_BATCH", 4096),
        read_target: env_or("READ_TARGET", 256),
        read_window: Duration::from_micros(env_or("READ_WINDOW_US", 5_000)),
        write_batch: env_or("WRITE_BATCH", 256),
        bcrypt_lanes: env_or::<usize>("BCRYPT_LANES", 8).clamp(1, 8),
        bcrypt_window: Duration::from_millis(env_or("BCRYPT_WINDOW_MS", 25)),
    }));

    // Fail fast if Postgres is unreachable or any statement fails to prepare.
    {
        let mut c = pg::Conn::connect(&settings.cfg).expect("connect to postgres");
        let stmts: Vec<_> = sql::read_statements().into_iter().chain(sql::write_statements()).collect();
        let list: Vec<(&str, &str, &[u32])> = stmts.iter().map(|s| (s.name, s.sql.as_str(), s.types)).collect();
        if let Err(e) = c.prepare_all(&list) {
            panic!("prepare: {e}");
        }
    }

    reply::init(io_threads);
    for _ in 0..read_lanes {
        let lane = db::ReadLane::new(settings);
        std::thread::Builder::new().name("read".into()).spawn(move || lane.run()).unwrap();
    }
    for _ in 0..write_lanes {
        let lane = db::WriteLane::new(settings);
        std::thread::Builder::new().name("write".into()).spawn(move || lane.run()).unwrap();
    }
    for i in 0..bcrypt_threads {
        std::thread::Builder::new().name("bcrypt".into()).spawn(move || db::bcrypt_worker(settings, i)).unwrap();
    }
    let mut handles = Vec::new();
    for t in 0..io_threads {
        let lfd = http::listener(&host, port).expect("listen");
        let server = http::Server::new(t as u16, lfd, keys).expect("epoll");
        handles.push(std::thread::Builder::new().name("io".into()).spawn(move || server.run()).unwrap());
    }
    eprintln!(
        "conduit listening on {host}:{port}: {io_threads} io threads, {read_lanes} read lanes, {write_lanes} write lanes, {bcrypt_threads} bcrypt threads"
    );
    for h in handles {
        let _ = h.join();
    }
}
