use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::get;
use axum::{Json, Router};
use serde::Deserialize;

use super::model::{ArticleChanges, ArticleEnvelope, ArticleList, NewArticle};
use super::service;
use crate::error::AppError;
use crate::features::auth::{viewer, Claims};
use crate::services::body::{non_empty_if_sent, required, JsonBody};
use crate::services::paging::ListQuery;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/articles", get(list).post(create))
        .route("/api/articles/feed", get(feed))
        .route("/api/articles/{slug}", get(by_slug).put(update).delete(delete))
}

#[derive(Deserialize)]
struct Wrapped<T> {
    article: T,
}

#[derive(Deserialize)]
struct CreateBody {
    title: Option<String>,
    description: Option<String>,
    body: Option<String>,
    #[serde(rename = "tagList")]
    tag_list: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct UpdateBody {
    title: Option<String>,
    description: Option<String>,
    body: Option<String>,
}

/// `GET /api/articles`
async fn list(claims: Option<Claims>, State(ctx): State<AppState>, query: ListQuery) -> Result<Json<ArticleList>, AppError> {
    let page = query.page()?;
    let list = service::list(&ctx, viewer(claims.as_ref()), service::filter_of(query), page).await?;
    Ok(Json(list))
}

/// `GET /api/articles/feed`
async fn feed(claims: Claims, State(ctx): State<AppState>, query: ListQuery) -> Result<Json<ArticleList>, AppError> {
    let list = service::feed(&ctx, claims.uid, query.page()?).await?;
    Ok(Json(list))
}

/// `GET /api/articles/{slug}`
async fn by_slug(claims: Option<Claims>, State(ctx): State<AppState>, Path(slug): Path<String>) -> Result<Json<ArticleEnvelope>, AppError> {
    let article = service::by_slug(&ctx, viewer(claims.as_ref()), &slug).await?;
    Ok(Json(ArticleEnvelope { article }))
}

/// `POST /api/articles`
async fn create(
    claims: Claims,
    State(ctx): State<AppState>,
    JsonBody(body): JsonBody<Wrapped<CreateBody>>,
) -> Result<(StatusCode, Json<ArticleEnvelope>), AppError> {
    let b = body.article;
    let tags = b.tag_list.unwrap_or_default();
    if tags.iter().any(String::is_empty) {
        return Err(AppError::UnprocessableEntity("tagList must hold non-empty strings"));
    }
    let new = NewArticle {
        title: required(b.title, "title is required")?,
        description: required(b.description, "description is required")?,
        body: required(b.body, "body is required")?,
        tags,
    };
    let article = service::create(&ctx, claims.uid, new).await?;
    Ok((StatusCode::CREATED, Json(ArticleEnvelope { article })))
}

/// `PUT /api/articles/{slug}`
async fn update(
    claims: Claims,
    State(ctx): State<AppState>,
    Path(slug): Path<String>,
    JsonBody(body): JsonBody<Wrapped<UpdateBody>>,
) -> Result<Json<ArticleEnvelope>, AppError> {
    let b = body.article;
    let changes = ArticleChanges {
        title: non_empty_if_sent(b.title, "title must not be empty")?,
        description: non_empty_if_sent(b.description, "description must not be empty")?,
        body: non_empty_if_sent(b.body, "body must not be empty")?,
    };
    let article = service::update(&ctx, claims.uid, &slug, changes).await?;
    Ok(Json(ArticleEnvelope { article }))
}

/// `DELETE /api/articles/{slug}`
async fn delete(claims: Claims, State(ctx): State<AppState>, Path(slug): Path<String>) -> Result<StatusCode, AppError> {
    service::delete(&ctx, claims.uid, &slug).await?;
    Ok(StatusCode::NO_CONTENT)
}
