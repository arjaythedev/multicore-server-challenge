pub mod articles;
pub mod auth;
pub mod comments;
pub mod favorites;
pub mod profiles;
pub mod tags;
pub mod users;

use axum::Router;

use crate::error::AppError;
use crate::services::db::Stmt;
use crate::AppState;

/// Every statement, prepared on each connection at boot.
pub fn statements() -> Vec<&'static Stmt> {
    [users::STATEMENTS, profiles::STATEMENTS, articles::STATEMENTS, favorites::STATEMENTS, comments::STATEMENTS, tags::STATEMENTS]
        .concat()
}

/// Every feature brings its own routes; an unknown path or method is the same JSON 404.
pub fn router() -> Router<AppState> {
    Router::new()
        .merge(users::route::router())
        .merge(profiles::route::router())
        .merge(articles::route::router())
        .merge(favorites::route::router())
        .merge(comments::route::router())
        .merge(tags::route::router())
        .fallback(|| async { AppError::NotFound })
        .method_not_allowed_fallback(|| async { AppError::NotFound })
}
