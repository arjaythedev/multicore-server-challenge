use axum::extract::{Path, State};
use axum::routing::{get, post};
use axum::{Json, Router};

use super::model::ProfileEnvelope;
use super::service;
use crate::error::AppError;
use crate::features::auth::{viewer, Claims};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/profiles/{username}", get(profile))
        .route("/api/profiles/{username}/follow", post(follow).delete(unfollow))
}

/// `GET /api/profiles/{username}`
async fn profile(
    claims: Option<Claims>,
    State(ctx): State<AppState>,
    Path(username): Path<String>,
) -> Result<Json<ProfileEnvelope>, AppError> {
    let profile = service::profile(&ctx, viewer(claims.as_ref()), &username).await?;
    Ok(Json(ProfileEnvelope { profile }))
}

/// `POST /api/profiles/{username}/follow`
async fn follow(claims: Claims, State(ctx): State<AppState>, Path(username): Path<String>) -> Result<Json<ProfileEnvelope>, AppError> {
    let profile = service::set_following(&ctx, claims.uid, &username, true).await?;
    Ok(Json(ProfileEnvelope { profile }))
}

/// `DELETE /api/profiles/{username}/follow`
async fn unfollow(claims: Claims, State(ctx): State<AppState>, Path(username): Path<String>) -> Result<Json<ProfileEnvelope>, AppError> {
    let profile = service::set_following(&ctx, claims.uid, &username, false).await?;
    Ok(Json(ProfileEnvelope { profile }))
}
