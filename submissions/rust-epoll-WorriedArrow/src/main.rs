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

fn main() {
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
    let secret = std::env::var("JWT_SECRET").expect("JWT_SECRET");
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port: u16 = env_or("PORT", 80);
    // SCHED_BATCH for this process (inherited by every thread it starts; no privileges needed): our threads wake up
    // constantly (a request, a reply, a batch ready) and under the default policy each wakeup may preempt a busy
    // Postgres backend. Batch threads still get their full CPU share, they just don't cut in line on wakeup.
    if env_or("SCHED_BATCH", 1) != 0 {
        let p = libc::sched_param { sched_priority: 0 };
        unsafe { libc::sched_setscheduler(0, libc::SCHED_BATCH, &p) };
    }
    // Raise the descriptor soft limit to the hard one (a setting of this process): every client holds a socket.
    unsafe {
        let mut l = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut l) == 0 && l.rlim_cur < l.rlim_max {
            l.rlim_cur = l.rlim_max;
            libc::setrlimit(libc::RLIMIT_NOFILE, &l);
        }
    }
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(8);

    let io_threads: usize = env_or("IO_THREADS", (cpus / 2).max(1));
    let read_lanes: usize = env_or("READ_LANES", cpus.max(2));
    let write_lanes: usize = env_or("WRITE_LANES", 1);
    let bcrypt_threads: usize = env_or("BCRYPT_THREADS", 2);

    // 0 (the default): time the CPU and pick the lockstep width.
    let bcrypt_lanes = match env_or::<usize>("BCRYPT_LANES", 0) {
        0 => bcrypt::calibrate(),
        n => n.clamp(1, 6),
    };
    let keys: &'static jwt::Keys = Box::leak(Box::new(jwt::Keys::new(secret.as_bytes())));
    let settings: &'static db::Settings = Box::leak(Box::new(db::Settings {
        cfg: pg::Config::parse(&url).expect("DATABASE_URL must be postgres://user:password@host:port/db"),
        keys,
        read_batch: env_or("READ_BATCH", 4096),
        read_min: env_or("READ_MIN", 4096),
        read_window: Duration::from_micros(env_or("READ_WINDOW_US", 40_000)),
        write_batch: env_or("WRITE_BATCH", 256),
        write_window: Duration::from_micros(env_or("WRITE_WINDOW_US", 3_000)),
        bcrypt_lanes,
        bcrypt_window: Duration::from_millis(env_or("BCRYPT_WINDOW_MS", 400)),
        bcrypt_idle: env_or("BCRYPT_IDLE", 0) != 0,
    }));

    // Fail fast if Postgres is unreachable or a statement doesn't prepare.
    {
        let mut c = pg::Conn::connect(&settings.cfg).expect("connect to postgres");
        let stmts: Vec<_> = sql::read_statements().into_iter().chain(sql::write_statements()).collect();
        let list: Vec<(&str, &str, &[u32])> = stmts.iter().map(|s| (s.name, s.sql.as_str(), s.types)).collect();
        if let Err(e) = c.prepare_all(&list) {
            panic!("prepare: {e}");
        }
    }

    http::ACK_DELAY.store(env_or("ACK_DELAY", 1) != 0, std::sync::atomic::Ordering::Relaxed);
    reply::init(io_threads);
    // FEED_LANES of the read lanes (and connections) serve only feeds; 0 (the default): every lane serves every read.
    // A fixed split caps feeds at those lanes' connections, and near saturation their queue can grow without bound.
    let feed_lanes: usize = env_or::<usize>("FEED_LANES", 0).min(read_lanes.saturating_sub(1));
    db::FEED_SPLIT.store(feed_lanes > 0, std::sync::atomic::Ordering::Relaxed);
    for i in 0..read_lanes {
        let pool = if i < feed_lanes { &db::FEEDS } else { &db::READS };
        let lane = db::ReadLane::new(settings, pool);
        std::thread::Builder::new().name("read".into()).spawn(move || lane.run()).unwrap();
    }
    for _ in 0..write_lanes {
        let lane = db::WriteLane::new(settings);
        std::thread::Builder::new().name("write".into()).spawn(move || lane.run()).unwrap();
    }
    for i in 0..bcrypt_threads {
        std::thread::Builder::new().name("bcrypt".into()).spawn(move || db::bcrypt_worker(settings, i)).unwrap();
    }
    if settings.bcrypt_idle {
        std::thread::Builder::new().name("bcrypt-rescue".into()).spawn(move || db::bcrypt_rescue(settings)).unwrap();
    }
    let mut handles = Vec::new();
    // Every IO thread takes a private copy of the descriptor table before any of them serves a request (see
    // Server::run); the barrier keeps the database lanes from opening sockets that a copy would then hold on to.
    let unshared = std::sync::Arc::new(std::sync::Barrier::new(io_threads));
    let private_fds = env_or("PRIVATE_FDS", 1) != 0;
    for t in 0..io_threads {
        let lfd = http::listener(&host, port).expect("listen");
        let server = http::Server::new(t as u16, lfd, keys).expect("epoll");
        let unshared = unshared.clone();
        handles.push(std::thread::Builder::new().name("io".into()).spawn(move || server.run(private_fds, &unshared)).unwrap());
    }
    eprintln!(
        "listening on {host}:{port}: {io_threads} io threads, {read_lanes} read lanes ({feed_lanes} for feeds), {write_lanes} write lanes, {bcrypt_threads} bcrypt threads x {bcrypt_lanes} lanes"
    );
    for h in handles {
        let _ = h.join();
    }
}
