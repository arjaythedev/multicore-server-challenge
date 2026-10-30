//! Conduit Apex: High-concurrency multicore RealWorld server in Rust.
#![allow(dead_code)]

use std::net::SocketAddr;
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

mod app;
mod config;
mod crypto;
mod json_out;
mod net;
mod pg;
mod time_fmt;

use app::batcher::{run_bcrypt_worker, run_read_worker, run_write_worker, BcryptRequest, ReadRequest, WriteRequest};
use app::handlers::route_and_dispatch;
use config::ServerConfig;
use net::http_parser::{parse_http_request, ParseResult};
use net::reactor::Reactor;
use net::socket::{create_listener, elevate_nofile_limit};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn main() {
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    elevate_nofile_limit();

    let config = ServerConfig::from_env();
    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .expect("Invalid HOST or PORT");

    // Spawn 16 read lanes with zero-contention channel distribution
    let mut read_senders = Vec::with_capacity(config.read_lanes);
    for _ in 0..config.read_lanes {
        let (tx, rx) = channel();
        read_senders.push(tx);
        let cfg = config.clone();
        std::thread::Builder::new()
            .name("conduit-read".to_string())
            .spawn(move || run_read_worker(rx, cfg))
            .expect("Failed to spawn read lane");
    }
    let read_channels = Arc::new(read_senders);
    let read_rr = Arc::new(AtomicUsize::new(0));

    // Spawn 2 write lanes
    let mut write_senders = Vec::with_capacity(config.write_lanes);
    for _ in 0..config.write_lanes {
        let (tx, rx) = channel();
        write_senders.push(tx);
        let cfg = config.clone();
        std::thread::Builder::new()
            .name("conduit-write".to_string())
            .spawn(move || run_write_worker(rx, cfg))
            .expect("Failed to spawn write lane");
    }
    let write_channels = Arc::new(write_senders);
    let write_rr = Arc::new(AtomicUsize::new(0));

    // Spawn 3 bcrypt workers
    let mut bcrypt_senders = Vec::with_capacity(config.bcrypt_workers);
    for _ in 0..config.bcrypt_workers {
        let (tx, rx) = channel();
        bcrypt_senders.push(tx);
        let cfg = config.clone();
        std::thread::Builder::new()
            .name("conduit-bcrypt".to_string())
            .spawn(move || run_bcrypt_worker(rx, cfg))
            .expect("Failed to spawn bcrypt lane");
    }
    let bcrypt_channels = Arc::new(bcrypt_senders);
    let bcrypt_rr = Arc::new(AtomicUsize::new(0));

    // Spawn IO workers with SO_REUSEPORT
    let mut io_handles = Vec::with_capacity(config.io_workers);
    for i in 0..config.io_workers {
        let read_ch = Arc::clone(&read_channels);
        let read_idx = Arc::clone(&read_rr);
        let write_ch = Arc::clone(&write_channels);
        let write_idx = Arc::clone(&write_rr);
        let bcrypt_ch = Arc::clone(&bcrypt_channels);
        let bcrypt_idx = Arc::clone(&bcrypt_rr);
        let secret = config.jwt_secret.clone();

        let handle = std::thread::Builder::new()
            .name(format!("conduit-io-{}", i))
            .spawn(move || {
                run_io_worker(
                    addr,
                    read_ch,
                    read_idx,
                    write_ch,
                    write_idx,
                    bcrypt_ch,
                    bcrypt_idx,
                    secret,
                );
            })
            .expect("Failed to spawn IO worker");
        io_handles.push(handle);
    }

    for h in io_handles {
        h.join().ok();
    }
}

fn run_io_worker(
    addr: SocketAddr,
    read_channels: Arc<Vec<Sender<ReadRequest>>>,
    read_rr: Arc<AtomicUsize>,
    write_channels: Arc<Vec<Sender<WriteRequest>>>,
    write_rr: Arc<AtomicUsize>,
    bcrypt_channels: Arc<Vec<Sender<BcryptRequest>>>,
    bcrypt_rr: Arc<AtomicUsize>,
    jwt_secret: Vec<u8>,
) {
    let listen_fd = match create_listener(addr) {
        Ok(fd) => fd,
        Err(e) => panic!("Listener creation failed on {}: {}", addr, e),
    };

    let mut reactor = Reactor::new(listen_fd).expect("Reactor init failed");
    let mut events = vec![
        libc::epoll_event {
            events: 0,
            u64: 0,
        };
        4096
    ];

    let mut read_scratch = [0u8; 8192];

    loop {
        let nfds = unsafe {
            libc::epoll_wait(
                reactor.epoll_fd,
                events.as_mut_ptr(),
                events.len() as libc::c_int,
                10,
            )
        };

        if nfds < 0 {
            let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if err == libc::EINTR {
                continue;
            }
            break;
        }

        let now_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        for i in 0..nfds as usize {
            let ev = &events[i];
            let fd = ev.u64 as RawFd;

            if fd == listen_fd {
                while let Some(_client_fd) = reactor.accept_connection() {}
                continue;
            }

            if (ev.events & ((libc::EPOLLRDHUP | libc::EPOLLERR | libc::EPOLLHUP) as u32)) != 0 {
                reactor.close_connection(fd);
                continue;
            }

            if (ev.events & (libc::EPOLLOUT as u32)) != 0 {
                reactor.handle_writable(fd);
            }

            if (ev.events & (libc::EPOLLIN as u32)) != 0 {
                let ufd = fd as usize;
                if ufd >= reactor.connections.len() || reactor.connections[ufd].is_none() {
                    continue;
                }

                let mut closed = false;
                loop {
                    let n = unsafe {
                        libc::recv(
                            fd,
                            read_scratch.as_mut_ptr() as *mut libc::c_void,
                            read_scratch.len(),
                            libc::MSG_DONTWAIT,
                        )
                    };

                    if n > 0 {
                        let conn = reactor.connections[ufd].as_mut().unwrap();
                        conn.read_buf.extend_from_slice(&read_scratch[..n as usize]);

                        loop {
                            let (consumed, should_close) = {
                                let c = reactor.connections[ufd].as_mut().unwrap();
                                match parse_http_request(&c.read_buf) {
                                    ParseResult::Complete(req) => {
                                        let consumed = req.consumed_len;
                                        let r_idx = read_rr.fetch_add(1, Ordering::Relaxed) % read_channels.len();
                                        let w_idx = write_rr.fetch_add(1, Ordering::Relaxed) % write_channels.len();
                                        let b_idx = bcrypt_rr.fetch_add(1, Ordering::Relaxed) % bcrypt_channels.len();

                                        route_and_dispatch(
                                            fd,
                                            req,
                                            &read_channels[r_idx],
                                            &write_channels[w_idx],
                                            &bcrypt_channels[b_idx],
                                            &jwt_secret,
                                            now_secs,
                                        );
                                        (Some(consumed), false)
                                    }
                                    ParseResult::Incomplete => (None, false),
                                    ParseResult::BadRequest => (None, true),
                                }
                            };

                            if should_close {
                                reactor.close_connection(fd);
                                closed = true;
                                break;
                            }

                            if let Some(len) = consumed {
                                let c = reactor.connections[ufd].as_mut().unwrap();
                                c.read_buf.drain(..len);
                                if c.read_buf.is_empty() {
                                    c.read_buf.shrink_to(1024);
                                    break;
                                }
                            } else {
                                break;
                            }
                        }
                        if closed {
                            break;
                        }
                    } else if n == 0 {
                        reactor.close_connection(fd);
                        break;
                    } else {
                        let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                        if err != libc::EAGAIN && err != libc::EWOULDBLOCK {
                            reactor.close_connection(fd);
                        }
                        break;
                    }
                }
            }
        }
    }
}
