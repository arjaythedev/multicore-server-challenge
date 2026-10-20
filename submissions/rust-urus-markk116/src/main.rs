//! Conduit (RealWorld) API server on urus + smarm. See README.md.

mod api;
mod auth;
mod db;
mod http;
mod model;
mod pwhash;
mod sql;

use std::sync::Arc;
use std::time::Duration;

use smarm::{ChildSpec, OneForOne, Restart, Shutdown};
use urus::Pipeline;

/// Process configuration, from the environment (SPEC.md "Runtime contract" plus tuning knobs).
struct Settings {
    database_url: String,
    jwt_secret: String,
    addr: std::net::SocketAddr,
    schedulers: usize,
    read_conns: usize,
    write_conns: usize,
}

fn fail(msg: &str) -> ! {
    eprintln!("conduit-urus: {msg}");
    std::process::exit(1)
}

impl Settings {
    fn from_env() -> Settings {
        let var = |k: &str| std::env::var(k).ok();
        let num = |k: &str, default: usize| var(k).map_or(default, |v| v.parse().unwrap_or_else(|_| fail(&format!("bad {k}"))));
        let cores = std::thread::available_parallelism().map_or(1, |n| n.get());
        let host = var("HOST").unwrap_or_else(|| "127.0.0.1".into());
        let port = var("PORT").unwrap_or_else(|| "3000".into());
        Settings {
            database_url: var("DATABASE_URL").unwrap_or_else(|| fail("DATABASE_URL is required")),
            jwt_secret: var("JWT_SECRET").unwrap_or_else(|| fail("JWT_SECRET is required")),
            addr: format!("{host}:{port}").parse().unwrap_or_else(|_| fail("bad HOST/PORT")),
            schedulers: num("SCHEDULERS", cores),
            // At most 100 Postgres connections on the box (SPEC.md). Writes are ~5% of requests.
            read_conns: num("DB_READ_CONNS", (cores * 4).clamp(2, 72)),
            write_conns: num("DB_WRITE_CONNS", cores.clamp(2, 24)),
        }
    }
}

/// smarm silences panic output inside actors (its trampoline catches them), and urus turns a
/// panicking handler into a bare 500, so without this a handler bug is invisible. Installed after
/// smarm's own hook (inside `run`), chaining to it. Stop sentinels (non-string payloads) are smarm's
/// cooperative cancellation, not bugs, and stay quiet.
fn log_actor_panics() {
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let p = info.payload();
        let msg = p.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| p.downcast_ref::<String>().cloned());
        match msg {
            Some(m) => {
                let at = info.location().map_or_else(|| "?".into(), |l| format!("{}:{}", l.file(), l.line()));
                eprintln!("[panic] {at}: {m}");
            }
            None => prev(info),
        }
    }));
}

const MAX_ACTORS: usize = 262_144;

fn main() {
    let s = Settings::from_env();
    let dbcfg = db::Config::parse(&s.database_url)
        .unwrap_or_else(|| fail("bad DATABASE_URL"))
        // Generic plans: the list statements otherwise re-plan on every execute (~0.5-0.7 ms each).
        // jit off: a generic plan with LIMIT $n is costed as the whole table and gets JIT-compiled.
        .option("plan_cache_mode", "force_generic_plan")
        .option("jit", "off");
    let (db, db_child) = db::Db::new(dbcfg, s.read_conns, s.write_conns);
    let app = Arc::new(api::App { db, jwt: auth::Jwt::new(&s.jwt_secret) });

    let pipeline = Pipeline::new().plug(api::routes(app)).plug(api::not_found);
    let http = urus::Config {
        // Well above a user's think time between pages (~7 s), so a browsing user keeps its connection.
        keep_alive_timeout: Duration::from_secs(75),
        ..urus::Config::new(s.addr)
    };
    // Bind before the runtime starts: address-in-use is a startup failure, not an actor crash.
    let endpoint = urus::endpoint(http, pipeline).unwrap_or_else(|e| fail(&format!("bind {}: {e}", s.addr)));

    eprintln!(
        "conduit-urus: {}, {} schedulers, {} + {} Postgres connections (read + write)",
        s.addr, s.schedulers, s.read_conns, s.write_conns
    );
    // One actor per client connection: smarm's default cap (16,384 live actors) panics the runtime once that
    // many connections are open. Above the box's LimitNOFILE (200,000), so file descriptors run out first, and
    // urus answers EMFILE by backing off. ~256 bytes per slot, allocated once.
    smarm::init(smarm::Config::exact(s.schedulers).max_actors(MAX_ACTORS)).run(move || {
        log_actor_panics();
        let root = smarm::spawn(move || {
            OneForOne::new()
                // Database first: the reverse-order shutdown stops it last, after the endpoint
                // has drained its in-flight requests.
                .child(db_child.clone())
                // The endpoint bounds its own drain (urus Config::drain_timeout).
                .child(ChildSpec::new(Restart::Permanent, endpoint.clone()).shutdown(Shutdown::Infinity))
                .run()
        });
        let _ = root.join();
    });
    // The tree only ends if a child exceeded its restart intensity: that's a crash, not a stop.
    fail("supervision tree exited");
}
