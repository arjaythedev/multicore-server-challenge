#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unreachable, clippy::todo, clippy::unimplemented))]

mod config;
mod error;
mod features;
mod services;

use std::net::SocketAddr;
use std::time::Duration;

use anyhow::Context;
use axum::serve::ListenerExt;
use tokio::net::TcpSocket;
use tracing_subscriber::EnvFilter;

use crate::services::db::{self, Db};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
}

fn main() {
    tracing_subscriber::fmt()
        .with_ansi(false)
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")))
        .init();
    let mut runtime = tokio::runtime::Builder::new_multi_thread();
    if let Some(threads) = config::env_opt_usize("APP_THREADS") {
        runtime.worker_threads(threads);
    }
    let runtime = match runtime.enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => refuse_to_boot(anyhow::Error::from(e)),
    };
    if let Err(e) = runtime.block_on(serve()) {
        refuse_to_boot(e);
    }
}

fn refuse_to_boot(e: anyhow::Error) -> ! {
    tracing::error!("REFUSING TO BOOT: {e:#}");
    std::process::exit(1);
}

async fn serve() -> anyhow::Result<()> {
    features::auth::assert_bootable()?;
    let database_url = std::env::var("DATABASE_URL").context("DATABASE_URL must be set")?;
    let db = connect(&database_url).await?;

    let addr: SocketAddr = format!("{}:{}", config::env_string("HOST", "127.0.0.1"), config::env_u32("PORT", 3000))
        .parse()
        .context("HOST:PORT is not a socket address")?;
    let socket = if addr.is_ipv4() { TcpSocket::new_v4()? } else { TcpSocket::new_v6()? };
    socket.set_reuseaddr(true)?;
    socket.bind(addr)?;
    let listener = socket.listen(config::env_u32("LISTEN_BACKLOG", 65_535))?.tap_io(|tcp| {
        if let Err(e) = tcp.set_nodelay(true) {
            tracing::debug!("TCP_NODELAY: {e}");
        }
    });

    let app = features::router().with_state(AppState { db });
    tracing::info!(%addr, "listening");
    axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await?;
    Ok(())
}

async fn connect(url: &str) -> anyhow::Result<Db> {
    let settings = db::Settings {
        read_connections: config::env_usize("DB_READ_CONNECTIONS", config::cores() * 2),
        write_connections: config::env_usize("DB_WRITE_CONNECTIONS", config::cores() * 2),
        transaction_connections: config::env_usize("DB_TRANSACTION_CONNECTIONS", 2),
        acquire_timeout: Duration::from_secs(config::env_u64("DB_ACQUIRE_TIMEOUT_SECS", 8)),
        statement_timeout_ms: config::env_u64("DB_STATEMENT_TIMEOUT_SECS", 30) * 1000,
        plan_cache_mode: config::env_string("DB_PLAN_CACHE_MODE", "force_generic_plan"),
    };
    Db::connect(url, settings, &features::statements()).await.context("can't connect to the database")
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if tokio::signal::ctrl_c().await.is_err() {
            std::future::pending::<()>().await;
        }
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {} }
}
