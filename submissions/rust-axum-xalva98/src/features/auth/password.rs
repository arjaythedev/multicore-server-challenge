//! bcrypt cost 10 on tokio's blocking pool, at most BCRYPT_THREADS at once so logins never take Postgres's cores.

use std::sync::LazyLock;

use tokio::sync::Semaphore;

use crate::config;
use crate::error::AppError;

const COST: u32 = 10;
const MAX_BYTES: usize = 72;

static PERMITS: LazyLock<Semaphore> = LazyLock::new(|| {
    Semaphore::new(config::env_opt_usize("BCRYPT_THREADS").unwrap_or_else(|| (config::cores() * 3 / 8).max(1)))
});

async fn on_blocking_pool<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> Result<T, AppError> {
    let _permit = PERMITS.acquire().await.map_err(|e| AppError::internal_server_error(format!("bcrypt permits: {e}")))?;
    tokio::task::spawn_blocking(work).await.map_err(|e| AppError::internal_server_error(format!("bcrypt task: {e}")))
}

/// bcrypt reads only 72 bytes: a longer password is refused rather than silently cut.
pub async fn hash(password: String) -> Result<String, AppError> {
    if password.len() > MAX_BYTES {
        return Err(AppError::UnprocessableEntity("password must be at most 72 bytes"));
    }
    on_blocking_pool(move || bcrypt::hash(password, COST))
        .await?
        .map_err(|e| AppError::internal_server_error(format!("bcrypt hash: {e}")))
}

pub async fn verify(password: String, stored_hash: String) -> Result<bool, AppError> {
    if password.len() > MAX_BYTES {
        return Ok(false);
    }
    on_blocking_pool(move || bcrypt::verify(password, &stored_hash).unwrap_or(false)).await
}
