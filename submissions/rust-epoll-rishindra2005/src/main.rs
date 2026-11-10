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
    let allowed = reactor::allowed_cpus();
    let cores = allowed.len();

    // Optimal Sprint 4 Zen 5 CPU layout:
    // - 4 IO workers (epoll listeners pinned to primary physical Cores 0, 1, 2, 3)
    // - 4 Read workers (pipelined binary queries pinned to SMT threads 12, 13, 14, 15)
    // - 1 Write worker (group commit pinned to SMT thread 13 of Core 1)
    // - 8 Crypto workers (unpinned across container cores under nice +2)
    let default_io = (cores / 2).max(2);
    let default_read = cores.max(8);
    let default_crypto = cores.max(8);

    let io_workers: usize = env_parse("IO_THREADS", default_io);
    let read_workers: usize = env_parse("READ_LANES", default_read);
    let write_workers: usize = env_parse("WRITE_LANES", 1);
    let crypto_workers: usize = env_parse("BCRYPT_THREADS", default_crypto);

    let affinity_mode = std::env::var("AFFINITY_MODE").unwrap_or_else(|_| "cfs".into());
    let is_cfs = affinity_mode.eq_ignore_ascii_case("cfs")
        || affinity_mode.eq_ignore_ascii_case("dynamic")
        || affinity_mode.eq_ignore_ascii_case("none")
        || affinity_mode == "0";

    // Approach B orthogonal partitioning (when AFFINITY_MODE=partitioned):
    // Core 0 & Core 1 (Primary: allowed[0], allowed[1]; SMT: allowed[4], allowed[5]) -> IO Reactors
    // Core 2 & Core 3 (Primary: allowed[2], allowed[3]; SMT: allowed[6], allowed[7]) -> DB Read
    // Core 3 SMT (allowed[7]) -> DB Write
    // SMT threads (allowed[4..8]) -> Crypto
    let io_cpus: Vec<usize> = if allowed.len() >= 8 {
        vec![allowed[0], allowed[1], allowed[4], allowed[5]]
    } else {
        vec![allowed[0], allowed[1 % allowed.len()]]
    };
    let read_cpus: Vec<usize> = if allowed.len() >= 8 {
        vec![allowed[2], allowed[3], allowed[6], allowed[7]]
    } else {
        vec![allowed[allowed.len() - 1]]
    };
    let write_cpus: Vec<usize> = if allowed.len() >= 8 {
        vec![allowed[7]]
    } else {
        vec![allowed[0]]
    };

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

    for idx in 0..read_workers {
        let worker = engine::ReadWorker::new(cfg);
        let cpu = read_cpus[idx % read_cpus.len()];
        std::thread::Builder::new()
            .name(format!("db-read-{idx}"))
            .spawn(move || {
                if !is_cfs {
                    reactor::pin_to_core(cpu);
                }
                worker.run_loop();
            })
            .unwrap();
    }
    for idx in 0..write_workers {
        let worker = engine::WriteWorker::new(cfg);
        let cpu = write_cpus[idx % write_cpus.len()];
        std::thread::Builder::new()
            .name(format!("db-write-{idx}"))
            .spawn(move || {
                if !is_cfs {
                    reactor::pin_to_core(cpu);
                }
                worker.run_loop();
            })
            .unwrap();
    }
    for idx in 0..crypto_workers {
        let cpu = if allowed.len() >= 8 {
            allowed[4 + (idx % 4)]
        } else {
            allowed[idx % allowed.len()]
        };
        std::thread::Builder::new()
            .name(format!("crypto-{idx}"))
            .spawn(move || {
                if !is_cfs {
                    reactor::pin_to_core(cpu);
                }
                reactor::set_thread_nice(2);
                engine::run_crypto_worker(cfg);
            })
            .unwrap();
    }

    let ready_barrier = std::sync::Arc::new(std::sync::Barrier::new(io_workers + 1));
    let mut handles = Vec::with_capacity(io_workers);
    for idx in 0..io_workers {
        let host = bind_host.clone();
        let bar = ready_barrier.clone();
        let cpu = io_cpus[idx % io_cpus.len()];
        handles.push(
            std::thread::Builder::new()
                .name(format!("io-reactor-{idx}"))
                .spawn(move || {
                    if !is_cfs {
                        reactor::pin_to_core(cpu);
                    }
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
        "listening on {bind_host}:{bind_port} ({io_workers} io, {read_workers} read, {write_workers} write, {crypto_workers}x{bcrypt_lanes} crypto, L1D={l1d_kb}KB, nofile={fd_budget}/io, cpuset={allowed:?}, affinity_mode={affinity_mode})"
    );
    for h in handles {
        let _ = h.join();
    }
}
