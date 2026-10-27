use axum::extract::{Path, State};
use axum::routing::post;
use axum::{Json, Router};

use super::service;
use crate::error::AppError;
use crate::features::articles::ArticleEnvelope;
use crate::features::auth::Claims;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/articles/{slug}/favorite", post(favorite).delete(unfavorite))
}

/// `POST /api/articles/{slug}/favorite`
async fn favorite(claims: Claims, State(ctx): State<AppState>, Path(slug): Path<String>) -> Result<Json<ArticleEnvelope>, AppError> {
    let article = service::set_favorite(&ctx, claims.uid, &slug, true).await?;
    Ok(Json(ArticleEnvelope { article }))
}

/// `DELETE /api/articles/{slug}/favorite`
async fn unfavorite(claims: Claims, State(ctx): State<AppState>, Path(slug): Path<String>) -> Result<Json<ArticleEnvelope>, AppError> {
    let article = service::set_favorite(&ctx, claims.uid, &slug, false).await?;
    Ok(Json(ArticleEnvelope { article }))
}
