//! Process entry: read the environment, start the lanes and the io threads, then park.

use std::process::ExitCode;
use std::sync::Arc;
use std::thread;

use conduit::app::App;
use conduit::config::Config;
use conduit::jwt::Jwt;
use conduit::net::{IoThread, Mailboxes};
use conduit::password::PasswordQueue;
use conduit::read::{self, ReadQueue};
use conduit::sys;
use conduit::write::{self, WriteQueue};

const LISTEN_BACKLOG: i32 = 4096;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("conduit: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let config = Config::from_env()?;
    if let Err(err) = sys::raise_nofile_limit() {
        eprintln!("conduit: cannot raise the descriptor limit: {err}");
    }
    let jwt = Arc::new(Jwt::new(&config.jwt_secret));
    let mailboxes = Mailboxes::new(config.io_threads).map_err(|e| format!("eventfd: {e}"))?;

    let read_queue = ReadQueue::new(config.read_window, config.read_batch_max);
    let write_queue = WriteQueue::new(config.write_window, config.write_batch_max);
    let password_queue = PasswordQueue::new(config.bcrypt_window);

    let mut threads = Vec::new();
    threads.extend(read::spawn_lanes(
        config.read_lanes,
        &config,
        read_queue.clone(),
        mailboxes.clone(),
        password_queue.clone(),
        jwt.clone(),
    ));
    threads.extend(write::spawn_lanes(
        config.write_lanes,
        &config,
        write_queue.clone(),
        mailboxes.clone(),
        jwt.clone(),
    ));
    threads.extend(conduit::password::spawn_threads(
        config.bcrypt_threads,
        &config,
        password_queue.clone(),
        mailboxes.clone(),
        write_queue.clone(),
        jwt.clone(),
    ));

    let app = Arc::new(App::new(jwt, read_queue, write_queue, password_queue));
    for index in 0..config.io_threads {
        let listener = sys::listen_reuseport(config.host, config.port, LISTEN_BACKLOG)
            .map_err(|e| format!("cannot listen on port {}: {e}", config.port))?;
        let io = IoThread::new(index as u16, listener, mailboxes.clone(), app.clone())
            .map_err(|e| format!("io thread {index}: {e}"))?;
        threads.push(
            thread::Builder::new()
                .name(format!("io-{index}"))
                .spawn(move || {
                    if let Err(err) = io.run() {
                        eprintln!("conduit: io thread {index} stopped: {err}");
                        std::process::exit(1);
                    }
                })
                .map_err(|e| format!("spawn: {e}"))?,
        );
    }
    eprintln!(
        "conduit: listening on {}.{}.{}.{}:{} ({} io, {} read lanes, {} write lanes, {} bcrypt)",
        config.host[0],
        config.host[1],
        config.host[2],
        config.host[3],
        config.port,
        config.io_threads,
        config.read_lanes,
        config.write_lanes,
        config.bcrypt_threads
    );
    for handle in threads {
        let _ = handle.join();
    }
    Ok(())
}
