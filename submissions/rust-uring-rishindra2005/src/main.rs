//! Main server boot: env parsing, thread layout, runtime wiring.
//! Owned by `io`.

use std::env;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use rust_uring_rishindra2005::net::create_reuseport_listener;
use rust_uring_rishindra2005::pg::wire::PgConfig;
use rust_uring_rishindra2005::rt::spsc::SpscQueue;
use rust_uring_rishindra2005::rt::thread::{create_eventfd, spawn_worker, SchedPolicy};
use rust_uring_rishindra2005::sec::kdf_worker::spawn_kdf_worker_indexed;
use rust_uring_rishindra2005::types::{Envelope, KdfJob, Reply};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() > 1 && args[1] == "--train" {
        rust_uring_rishindra2005::train::run_training_workload();
        return;
    }

    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(80);

    let allowed_cpus = rust_uring_rishindra2005::rt::thread::get_allowed_cpus();
    let num_cpus = allowed_cpus.len();

    let default_net_threads = (num_cpus / 2).max(1);
    let net_threads: usize = env::var("NET_THREADS")
        .ok()
        .and_then(|n| n.parse().ok())
        .unwrap_or(default_net_threads);

    let default_pg_threads = (num_cpus / 4).max(1).min(2);
    let pg_threads: usize = env::var("PG_THREADS")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(default_pg_threads);

    let default_kdf_threads = 1;
    let kdf_threads: usize = env::var("KDF_THREADS")
        .ok()
        .and_then(|k| k.parse().ok())
        .unwrap_or(default_kdf_threads);

    let db_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://postgres:postgres@127.0.0.1:5432/conduit".to_string());

    let direct_sz: u32 = env::var("DIRECT_TABLE_SZ")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(190_000);

    println!(
        "Booting rust-uring-rishindra2005: port={}, net_threads={} (default={}), pg_threads={} (default={}), kdf_threads={} (default={}), direct_sz={}, allowed_cpus={}, db={}",
        port, net_threads, default_net_threads, pg_threads, default_pg_threads, kdf_threads, default_kdf_threads, direct_sz, num_cpus, db_url
    );
    println!("KDF batch window: {} ms", rust_uring_rishindra2005::sec::kdf_worker::get_batch_window().as_millis());

    let stop_signal = Arc::new(AtomicBool::new(false));

    // Register clean signal handling
    extern "C" fn on_sig(_sig: libc::c_int) {
        unsafe { libc::_exit(0); }
    }
    unsafe {
        libc::signal(libc::SIGINT, on_sig as *const () as usize);
        libc::signal(libc::SIGTERM, on_sig as *const () as usize);
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    // Dedicated wakeup eventfds for net reactors (used to wake reactor ring on inbound replies)
    let mut reactor_wake_fds = Vec::with_capacity(net_threads);
    for _ in 0..net_threads {
        reactor_wake_fds.push(create_eventfd().unwrap_or(-1));
    }

    // Dedicated wakeup eventfds for PG drivers (shared across all in_queues of driver p)
    let mut pg_driver_wake_fds = Vec::with_capacity(pg_threads);
    for _ in 0..pg_threads {
        pg_driver_wake_fds.push(create_eventfd().unwrap_or(-1));
    }

    // Dedicated wakeup eventfds for KDF workers (shared across all in_queues of worker k)
    let mut kdf_worker_wake_fds = Vec::with_capacity(kdf_threads);
    for _ in 0..kdf_threads {
        kdf_worker_wake_fds.push(create_eventfd().unwrap_or(-1));
    }

    // Set up lock-free SPSC queue matrices:
    // 1. Net -> PG: SpscQueue<Envelope, 1024> per (net_idx, pg_idx)
    // Producer: net-reactor-i, Consumer: pg-driver-p
    let mut pg_queues: Vec<Vec<Arc<SpscQueue<Envelope, 1024>>>> = Vec::with_capacity(net_threads);
    for _ in 0..net_threads {
        let mut row = Vec::with_capacity(pg_threads);
        for pg_idx in 0..pg_threads {
            let efd = pg_driver_wake_fds[pg_idx];
            row.push(Arc::new(SpscQueue::<Envelope, 1024>::new(efd)));
        }
        pg_queues.push(row);
    }

    // 2. Net -> KDF: SpscQueue<KdfJob, 512> per (net_idx, kdf_idx)
    // Producer: net-reactor-i, Consumer: kdf-worker-k
    let mut kdf_net_queues: Vec<Vec<Arc<SpscQueue<KdfJob, 512>>>> = Vec::with_capacity(net_threads);
    for _ in 0..net_threads {
        let mut row = Vec::with_capacity(kdf_threads);
        for kdf_idx in 0..kdf_threads {
            let efd = kdf_worker_wake_fds[kdf_idx];
            row.push(Arc::new(SpscQueue::<KdfJob, 512>::new(efd)));
        }
        kdf_net_queues.push(row);
    }

    // 3. PG -> KDF: SpscQueue<KdfJob, 512> per pg_idx
    // Producer: pg-driver-p, Consumer: kdf-worker-(p % kdf_threads)
    let mut kdf_pg_queues: Vec<Arc<SpscQueue<KdfJob, 512>>> = Vec::with_capacity(pg_threads);
    for pg_idx in 0..pg_threads {
        let kdf_idx = pg_idx % kdf_threads;
        let efd = kdf_worker_wake_fds[kdf_idx];
        kdf_pg_queues.push(Arc::new(SpscQueue::<KdfJob, 512>::new(efd)));
    }

    // 4. PG -> Net: SpscQueue<Reply, 1024> per (pg_idx, net_idx)
    // Producer: pg-driver-p, Consumer: net-reactor-i
    // Eventfd: reactor_wake_fds[net_idx] (signals net-reactor-i when replies arrive)
    let mut reply_queues: Vec<Vec<Arc<SpscQueue<Reply, 1024>>>> = Vec::with_capacity(pg_threads);
    for _ in 0..pg_threads {
        let mut row = Vec::with_capacity(net_threads);
        for net_idx in 0..net_threads {
            let efd = reactor_wake_fds[net_idx];
            row.push(Arc::new(SpscQueue::<Reply, 1024>::new(efd)));
        }
        reply_queues.push(row);
    }

    // 5. KDF -> Net: SpscQueue<Reply, 512> per (kdf_idx, net_idx)
    // Producer: kdf-worker-k, Consumer: net-reactor-i
    // Eventfd: reactor_wake_fds[net_idx] (signals net-reactor-i when replies arrive)
    let mut kdf_reply_queues: Vec<Vec<Arc<SpscQueue<Reply, 512>>>> = Vec::with_capacity(kdf_threads);
    for _ in 0..kdf_threads {
        let mut row = Vec::with_capacity(net_threads);
        for net_idx in 0..net_threads {
            let efd = reactor_wake_fds[net_idx];
            row.push(Arc::new(SpscQueue::<Reply, 512>::new(efd)));
        }
        kdf_reply_queues.push(row);
    }

    // 6. KDF -> PG: SpscQueue<Envelope, 1024> per (kdf_idx, pg_idx)
    // Producer: kdf-worker-k, Consumer: pg-driver-p
    // Dedicated per worker and driver per R1 (prevents multi-producer race)
    let mut kdf_to_pg_queues: Vec<Vec<Arc<SpscQueue<Envelope, 1024>>>> = Vec::with_capacity(kdf_threads);
    for _ in 0..kdf_threads {
        let mut row = Vec::with_capacity(pg_threads);
        for pg_idx in 0..pg_threads {
            let efd = pg_driver_wake_fds[pg_idx];
            row.push(Arc::new(SpscQueue::<Envelope, 1024>::new(efd)));
        }
        kdf_to_pg_queues.push(row);
    }

    let mut handles = Vec::new();

    // Compute CPU affinity placement across physical cores (1 thread per core first)
    let (net_pins, pg_pins, affinity_log) = rust_uring_rishindra2005::rt::thread::build_affinity_map(
        net_threads,
        pg_threads,
    );
    println!("{}", affinity_log);

    // 1. Spawn KDF Worker pool (SCHED_BATCH, nice 5, unpinned)
    for kdf_idx in 0..kdf_threads {
        let mut in_queues = Vec::with_capacity(net_threads + 1);
        for net_idx in 0..net_threads {
            in_queues.push(kdf_net_queues[net_idx][kdf_idx].clone());
        }
        for pg_idx in 0..pg_threads {
            if pg_idx % kdf_threads == kdf_idx {
                in_queues.push(kdf_pg_queues[pg_idx].clone());
            }
        }
        let reply_queues_for_worker: Vec<Arc<SpscQueue<Reply, 512>>> = (0..net_threads)
            .map(|net_idx| kdf_reply_queues[kdf_idx][net_idx].clone())
            .collect();
        let pg_queues_for_worker: Vec<Arc<SpscQueue<Envelope, 1024>>> = (0..pg_threads)
            .map(|pg_idx| kdf_to_pg_queues[kdf_idx][pg_idx].clone())
            .collect();

        let handle = spawn_kdf_worker_indexed(
            kdf_idx,
            in_queues,
            reply_queues_for_worker,
            pg_queues_for_worker,
            stop_signal.clone(),
        );
        handles.push(handle);
    }

    // 2. Spawn PG Driver threads (SCHED_BATCH, pinned to dedicated SMT sibling cores)
    let db_config = match PgConfig::from_url(&db_url) {
        Ok(cfg) => cfg,
        Err(e) => {
            eprintln!("Failed to parse DATABASE_URL ({}): {:?}", db_url, e);
            return;
        }
    };

    for pg_idx in 0..pg_threads {
        let cfg = db_config.clone();
        let stop_clone = stop_signal.clone();
        let cpu_id = pg_pins[pg_idx];

        let mut in_queues_for_driver: Vec<Arc<SpscQueue<Envelope, 1024>>> = (0..net_threads)
            .map(|net_idx| pg_queues[net_idx][pg_idx].clone())
            .collect();
        for kdf_idx in 0..kdf_threads {
            in_queues_for_driver.push(kdf_to_pg_queues[kdf_idx][pg_idx].clone());
        }

        let reply_queues_for_driver: Vec<Arc<SpscQueue<Reply, 1024>>> = (0..net_threads)
            .map(|net_idx| reply_queues[pg_idx][net_idx].clone())
            .collect();

        let kdf_q = kdf_pg_queues[pg_idx].clone();

        let handle = spawn_worker(
            &format!("pg-driver-{}", pg_idx),
            cpu_id,
            SchedPolicy::Batch,
            move || {
                loop {
                    match rust_uring_rishindra2005::plan::run_pg_driver(
                        pg_idx,
                        cfg.clone(),
                        in_queues_for_driver.clone(),
                        reply_queues_for_driver.clone(),
                        kdf_q.clone(),
                        stop_clone.clone(),
                    ) {
                        Ok(()) => break,
                        Err(err) => {
                            eprintln!("pg-driver-{} error: {:?}. Retrying in 1s...", pg_idx, err);
                            std::thread::sleep(Duration::from_secs(1));
                            if stop_clone.load(Ordering::Relaxed) {
                                break;
                            }
                        }
                    }
                }
            },
        )
        .expect("spawn pg driver");

        handles.push(handle);
    }

    // 3. Spawn Net Reactor threads (SCHED_BATCH, pinned to physical cores)
    for net_idx in 0..net_threads {
        let stop_clone = stop_signal.clone();
        let cpu_id = net_pins[net_idx];
        let wake_fd = reactor_wake_fds[net_idx];

        let pg_refs: Vec<Arc<SpscQueue<Envelope, 1024>>> = (0..pg_threads)
            .map(|pg_idx| pg_queues[net_idx][pg_idx].clone())
            .collect();

        let reply_refs: Vec<Arc<SpscQueue<Reply, 1024>>> = (0..pg_threads)
            .map(|pg_idx| reply_queues[pg_idx][net_idx].clone())
            .collect();

        let kdf_refs: Vec<Arc<SpscQueue<KdfJob, 512>>> = (0..kdf_threads)
            .map(|kdf_idx| kdf_net_queues[net_idx][kdf_idx].clone())
            .collect();

        let kdf_reply_refs: Vec<Arc<SpscQueue<Reply, 512>>> = (0..kdf_threads)
            .map(|kdf_idx| kdf_reply_queues[kdf_idx][net_idx].clone())
            .collect();

        let handle = spawn_worker(
            &format!("net-reactor-{}", net_idx),
            cpu_id,
            SchedPolicy::Batch,
            move || {
                let listen_fd = match create_reuseport_listener(port) {
                    Ok(fd) => fd,
                    Err(e) => {
                        eprintln!("net-reactor-{} failed to bind port {}: {}", net_idx, port, e);
                        return;
                    }
                };

                // Try io_uring first with direct descriptors and eventfd ring wakeup
                let uring_res = rust_uring_rishindra2005::net::UringReactor::new(
                    net_idx as u8,
                    listen_fd,
                    direct_sz,
                    wake_fd,
                );

                match uring_res {
                    Ok(mut reactor) => {
                        println!(
                            "ACTIVE BACKEND: io_uring (net-reactor-{} with Direct Descriptors: {}, wake_fd: {})",
                            net_idx, direct_sz, wake_fd
                        );

                        let mut completions = Vec::with_capacity(512);

                        while !stop_clone.load(Ordering::Relaxed) {
                            // 0. Flush overflow queues to PG and KDF workers
                            reactor.flush_overflow(&pg_refs, &kdf_refs);

                            // 1. Drain replies from PG drivers and KDF workers
                            reactor.drain_replies(&reply_refs, &kdf_reply_refs);

                            // 2. Prepare sends and submit
                            let queued_sends = reactor.flush_outgoing_sends();

                            // 2.5. Re-arm starved recvs after buffers returned by previous dispatch
                            reactor.rearm_starved();

                            // 3. Submit and wait:
                            // If sends are queued or overflow is active, do not wait (non-blocking submit).
                            // Otherwise, mark queues sleeping and wait with timeout_us = 0 (infinite block until work arrives).
                            let (min_complete, wait_timeout_us) = if queued_sends > 0 || reactor.has_overflow() {
                                (0, 0)
                            } else if wake_fd < 0 {
                                (1, 50)
                            } else {
                                for q in &reply_refs {
                                    q.mark_sleeping();
                                }
                                for q in &kdf_reply_refs {
                                    q.mark_sleeping();
                                }
                                std::sync::atomic::fence(Ordering::SeqCst);

                                let has_replies = reply_refs.iter().any(|q| !q.is_empty())
                                    || kdf_reply_refs.iter().any(|q| !q.is_empty())
                                    || reactor.has_overflow();

                                if has_replies {
                                    for q in &reply_refs {
                                        q.mark_awake();
                                    }
                                    for q in &kdf_reply_refs {
                                        q.mark_awake();
                                    }
                                    (0, 0)
                                } else {
                                    reactor.arm_wakeup();
                                    (1, 0)
                                }
                            };

                            let _ = reactor.ring.submit_and_wait_timeout(min_complete, wait_timeout_us);

                            for q in &reply_refs {
                                q.mark_awake();
                            }
                            for q in &kdf_reply_refs {
                                q.mark_awake();
                            }

                            // 4. Harvest CQEs
                            completions.clear();
                            reactor.ring.for_each_cqe(|cqe| {
                                completions.push(*cqe);
                            });

                            // 5. Dispatch CQEs
                            for cqe in &completions {
                                if cqe.user_data == rust_uring_rishindra2005::net::TOKEN_ACCEPT {
                                    reactor.handle_accept_cqe(cqe);
                                } else if cqe.user_data == rust_uring_rishindra2005::net::TOKEN_WAKEUP {
                                    reactor.wake_inflight = false;
                                } else if cqe.user_data == rust_uring_rishindra2005::net::TOKEN_CLOSE {
                                    // Direct descriptor close completed
                                } else {
                                    let (tag, slot_idx, gen24) =
                                        rust_uring_rishindra2005::net::unpack_user_data(cqe.user_data);
                                    match tag {
                                        rust_uring_rishindra2005::net::TAG_RECV => {
                                            reactor.handle_recv_cqe(
                                                slot_idx,
                                                gen24,
                                                cqe,
                                                &pg_refs,
                                                &kdf_refs,
                                            );
                                        }
                                        rust_uring_rishindra2005::net::TAG_SEND => {
                                            reactor.handle_send_cqe(slot_idx, gen24, cqe.res);
                                        }
                                        _ => {}
                                    }
                                }
                            }
                        }
                    }
                    Err(err) => {
                        eprintln!(
                            "io_uring setup failed (errno={}), falling back to epoll reactor...",
                            err
                        );
                        let mut ep_reactor = rust_uring_rishindra2005::net::epoll::EpollReactor::new(
                            net_idx as u8,
                            listen_fd,
                            32768,
                        )
                        .expect("epoll fallback init");
                        println!("net-reactor-{} running on epoll fallback", net_idx);

                        let mut events = vec![libc::epoll_event { events: 0, u64: 0 }; 512];
                        while !stop_clone.load(Ordering::Relaxed) {
                            // 0. Flush overflow queues to PG and KDF workers
                            ep_reactor.flush_overflow(&pg_refs, &kdf_refs);

                            // 1. Drain replies from PG drivers and KDF worker
                            ep_reactor.drain_replies(&reply_refs, &kdf_reply_refs);

                            // 2. Flush sends
                            ep_reactor.flush_sends();

                            // 3. Wait for epoll events (timeout 50ms if idle, 0ms if overflow active)
                            let timeout_ms = if ep_reactor.has_overflow() { 0 } else { 50 };
                            let n = unsafe {
                                libc::epoll_wait(
                                    ep_reactor.ep_fd,
                                    events.as_mut_ptr(),
                                    events.len() as i32,
                                    timeout_ms,
                                )
                            };
                            if n <= 0 {
                                continue;
                            }

                            for i in 0..n as usize {
                                let ev = &events[i];
                                if ev.u64 == u64::MAX {
                                    ep_reactor.accept_connections();
                                } else {
                                    let slot_idx = ev.u64 as u32;
                                    ep_reactor.handle_event(
                                        slot_idx,
                                        ev.events,
                                        &pg_refs,
                                        &kdf_refs,
                                    );
                                }
                            }
                        }
                    }
                }
            },
        )
        .expect("spawn net reactor");

        handles.push(handle);
    }

    println!("All {} net reactors active. Server ready.", net_threads);

    for h in handles {
        let _ = h.join();
    }
}
