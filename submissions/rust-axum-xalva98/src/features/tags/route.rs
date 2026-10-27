use axum::extract::State;
use axum::routing::get;
use axum::{Json, Router};
use serde::Serialize;

use super::service;
use crate::error::AppError;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/tags", get(all))
}

#[derive(Serialize)]
struct TagList {
    tags: Vec<String>,
}

/// `GET /api/tags`: also the health check.
async fn all(State(ctx): State<AppState>) -> Result<Json<TagList>, AppError> {
    Ok(Json(TagList { tags: service::all(&ctx).await? }))
}
