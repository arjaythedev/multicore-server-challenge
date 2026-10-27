//! HTTP layer for accounts: parse and validate, call the service, shape the response.

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;

use super::model::UserEnvelope;
use super::service::{self, Settings, SignUp};
use crate::error::AppError;
use crate::features::auth::Claims;
use crate::services::body::{non_empty_if_sent, required, JsonBody};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/users", post(register))
        .route("/api/users/login", post(login))
        .route("/api/user", get(current).put(update))
}

#[derive(Deserialize)]
struct Wrapped<T> {
    user: T,
}

#[derive(Deserialize)]
struct RegisterBody {
    username: Option<String>,
    email: Option<String>,
    password: Option<String>,
}

#[derive(Deserialize)]
struct LoginBody {
    email: Option<String>,
    password: Option<String>,
}

#[derive(Deserialize)]
struct SettingsBody {
    email: Option<String>,
    username: Option<String>,
    password: Option<String>,
    bio: Option<String>,
    image: Option<String>,
}

/// `POST /api/users`
async fn register(
    State(ctx): State<AppState>,
    JsonBody(body): JsonBody<Wrapped<RegisterBody>>,
) -> Result<(StatusCode, Json<UserEnvelope>), AppError> {
    let input = SignUp {
        username: required(body.user.username, "username is required")?,
        email: required(body.user.email, "email is required")?,
        password: required(body.user.password, "password is required")?,
    };
    let user = service::register(&ctx, input).await?;
    Ok((StatusCode::CREATED, Json(UserEnvelope { user })))
}

/// `POST /api/users/login`
async fn login(State(ctx): State<AppState>, JsonBody(body): JsonBody<Wrapped<LoginBody>>) -> Result<Json<UserEnvelope>, AppError> {
    let email = required(body.user.email, "email is required")?;
    let password = required(body.user.password, "password is required")?;
    let user = service::login(&ctx, &email, password).await?;
    Ok(Json(UserEnvelope { user }))
}

/// `GET /api/user`
async fn current(claims: Claims, State(ctx): State<AppState>) -> Result<Json<UserEnvelope>, AppError> {
    let user = service::current(&ctx, claims).await?;
    Ok(Json(UserEnvelope { user }))
}

/// `PUT /api/user`
async fn update(
    claims: Claims,
    State(ctx): State<AppState>,
    JsonBody(body): JsonBody<Wrapped<SettingsBody>>,
) -> Result<Json<UserEnvelope>, AppError> {
    let b = body.user;
    let input = Settings {
        email: non_empty_if_sent(b.email, "email must not be empty")?,
        username: non_empty_if_sent(b.username, "username must not be empty")?,
        password: non_empty_if_sent(b.password, "password must not be empty")?,
        bio: b.bio,
        image: b.image,
    };
    let user = service::update(&ctx, claims, input).await?;
    Ok(Json(UserEnvelope { user }))
}
