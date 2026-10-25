use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{delete, get};
use axum::{Json, Router};
use serde::Deserialize;

use super::model::{CommentEnvelope, CommentList};
use super::service;
use crate::error::AppError;
use crate::features::auth::{viewer, Claims};
use crate::services::body::{required, JsonBody};
use crate::services::paging::digits;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/articles/{slug}/comments", get(thread).post(add))
        .route("/api/articles/{slug}/comments/{id}", delete(remove))
}

#[derive(Deserialize)]
struct Wrapped {
    comment: AddBody,
}

#[derive(Deserialize)]
struct AddBody {
    body: Option<String>,
}

/// `GET /api/articles/{slug}/comments`
async fn thread(claims: Option<Claims>, State(ctx): State<AppState>, Path(slug): Path<String>) -> Result<Json<CommentList>, AppError> {
    let list = service::thread(&ctx, viewer(claims.as_ref()), &slug).await?;
    Ok(Json(list))
}

/// `POST /api/articles/{slug}/comments`
async fn add(
    claims: Claims,
    State(ctx): State<AppState>,
    Path(slug): Path<String>,
    JsonBody(body): JsonBody<Wrapped>,
) -> Result<(StatusCode, Json<CommentEnvelope>), AppError> {
    let text = required(body.comment.body, "body is required")?;
    let comment = service::add(&ctx, claims.uid, &slug, &text).await?;
    Ok((StatusCode::CREATED, Json(CommentEnvelope { comment })))
}

/// `DELETE /api/articles/{slug}/comments/{id}`: an id that is not an integer names no comment.
async fn remove(claims: Claims, State(ctx): State<AppState>, Path((slug, id)): Path<(String, String)>) -> Result<StatusCode, AppError> {
    let id = digits(&id).ok_or(AppError::NotFound)?;
    service::delete(&ctx, claims.uid, &slug, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
