mod auth;
mod codec;
mod engine;
mod queries;
mod reactor;
mod router;
mod wire;

fn env_parse<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn main() {
    unsafe {
        reactor::sys::prctl(reactor::sys::PR_SET_THP_DISABLE, 1, 0, 0, 0);
        reactor::sys::mallopt(reactor::sys::M_ARENA_MAX, 4);
        let param = reactor::sys::sched_param { sched_priority: 0 };
        reactor::sys::sched_setscheduler(0, reactor::sys::SCHED_BATCH, &param);
    }

    let db_url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let jwt_secret = std::env::var("JWT_SECRET").expect("JWT_SECRET must be set");
    let bind_host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let bind_port: u16 = env_parse("PORT", 80);
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(8);

    let io_workers: usize = env_parse("IO_THREADS", (cores / 2).max(2));
    let read_workers: usize = env_parse("READ_LANES", cores.max(4));
    let write_workers: usize = env_parse("WRITE_LANES", 1);
    let crypto_workers: usize = env_parse("BCRYPT_THREADS", cores.max(4));

    let (auto_lanes, seed_bcrypt_us, l1d_kb) = auth::calibrate_bcrypt_hardware();
    let bcrypt_lanes: usize = env_parse("BCRYPT_LANES", auto_lanes);

    let signer: &'static auth::TokenSigner = Box::leak(Box::new(auth::TokenSigner::new(jwt_secret.as_bytes())));
    let cfg: &'static engine::RuntimeConfig = Box::leak(Box::new(engine::RuntimeConfig {
        db: wire::DbEndpoint::parse(&db_url).expect("invalid DATABASE_URL"),
        signer,
        read_workers,
        bcrypt_lanes,
    }));

    {
        let mut probe = wire::PgConn::connect(&cfg.db).expect("failed to connect to PostgreSQL");
        let all_defs: Vec<_> = queries::read_catalog()
            .into_iter()
            .chain(queries::write_catalog())
            .collect();
        let refs: Vec<(&str, &str, &[u32])> = all_defs
            .iter()
            .map(|d| (d.name, d.sql.as_str(), d.oids))
            .collect();
        if let Err(err) = probe.prepare_batch(&refs) {
            panic!("PostgreSQL statement preparation failed: {err}");
        }
        engine::seed_hardware_ewma((seed_bcrypt_us >> 7).max(600), seed_bcrypt_us);
    }

    let fd_budget = reactor::probe_nofile_limit();
    reactor::init_outboxes(io_workers, fd_budget);

    for _ in 0..read_workers {
        let worker = engine::ReadWorker::new(cfg);
        std::thread::Builder::new()
            .name("db-read".into())
            .spawn(move || worker.run_loop())
            .unwrap();
    }
    for _ in 0..write_workers {
        let worker = engine::WriteWorker::new(cfg);
        std::thread::Builder::new()
            .name("db-write".into())
            .spawn(move || worker.run_loop())
            .unwrap();
    }
    for _ in 0..crypto_workers {
        std::thread::Builder::new()
            .name("crypto".into())
            .spawn(move || engine::run_crypto_worker(cfg))
            .unwrap();
    }

    let ready_barrier = std::sync::Arc::new(std::sync::Barrier::new(io_workers + 1));
    let mut handles = Vec::with_capacity(io_workers);
    for idx in 0..io_workers {
        let host = bind_host.clone();
        let bar = ready_barrier.clone();
        handles.push(
            std::thread::Builder::new()
                .name("io-reactor".into())
                .spawn(move || {
                    reactor::unshare_files();
                    let lfd = reactor::bind_listener(&host, bind_port).expect("failed to bind listener");
                    let srv = reactor::Reactor::new(idx as u16, lfd, signer, fd_budget)
                        .expect("failed to init epoll reactor");
                    bar.wait();
                    srv.run_loop();
                })
                .unwrap(),
        );
    }
    ready_barrier.wait();

    eprintln!(
        "listening on {bind_host}:{bind_port} ({io_workers} io, {read_workers} read, {write_workers} write, {crypto_workers}x{bcrypt_lanes} crypto, L1D={l1d_kb}KB, nofile={fd_budget}/io)"
    );
    for h in handles {
        let _ = h.join();
    }
}
