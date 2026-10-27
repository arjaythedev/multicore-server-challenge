use axum::http::header::WWW_AUTHENTICATE;
use axum::http::{HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

#[derive(thiserror::Error, Debug)]
pub enum AppError {
    #[error("authentication required")]
    Unauthorized,

    #[error("user may not perform that action")]
    Forbidden,

    #[error("not found")]
    NotFound,

    /// The message IS shown to the client: never internal detail.
    #[error("{0}")]
    UnprocessableEntity(&'static str),

    /// `detail` goes to the server log only; the client gets a generic message and the id of the log line.
    #[error("an internal server error occurred")]
    Internal { detail: String },
}

const SAFE_INTERNAL_MESSAGE: &str = "An internal error occurred. Please try again.";

impl AppError {
    pub fn internal_server_error(message: impl Into<String>) -> Self {
        Self::Internal { detail: message.into() }
    }

    /// `.map_err(AppError::db("what failed"))` for a query error.
    pub fn db(what: &'static str) -> impl Fn(tokio_postgres::Error) -> AppError {
        move |e| AppError::internal_server_error(format!("{what}: {e}"))
    }

    /// SQLSTATE 23505 becomes the client's 422, anything else stays internal.
    pub fn unique_or_db(taken: &'static str, what: &'static str) -> impl Fn(tokio_postgres::Error) -> AppError {
        move |e| match e.code() {
            Some(code) if *code == tokio_postgres::error::SqlState::UNIQUE_VIOLATION => AppError::UnprocessableEntity(taken),
            _ => AppError::internal_server_error(format!("{what}: {e}")),
        }
    }

    fn status_code(&self) -> StatusCode {
        match self {
            Self::Unauthorized => StatusCode::UNAUTHORIZED,
            Self::Forbidden => StatusCode::FORBIDDEN,
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::UnprocessableEntity(_) => StatusCode::UNPROCESSABLE_ENTITY,
            Self::Internal { .. } => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }
}

/// The envelope the API specifies: `{"errors": {"body": [..]}}`.
#[derive(Serialize)]
struct Envelope<'a> {
    errors: Messages<'a>,
}

#[derive(Serialize)]
struct Messages<'a> {
    body: [&'a str; 1],
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = self.status_code();
        let internal;
        let message = match &self {
            Self::Internal { detail } => {
                let id = uuid::Uuid::new_v4();
                tracing::error!(error_id = %id, "internal error: {detail}");
                internal = format!("{SAFE_INTERNAL_MESSAGE} ({id})");
                internal.as_str()
            }
            Self::UnprocessableEntity(message) => message,
            Self::Unauthorized => "authentication required",
            Self::Forbidden => "user may not perform that action",
            Self::NotFound => "not found",
        };
        let mut response = (status, Json(Envelope { errors: Messages { body: [message] } })).into_response();
        if matches!(self, Self::Unauthorized) {
            response.headers_mut().insert(WWW_AUTHENTICATE, HeaderValue::from_static("Token"));
        }
        response
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn body_of(e: AppError) -> (StatusCode, serde_json::Value) {
        let resp = e.into_response();
        let status = resp.status();
        let bytes = axum::body::to_bytes(resp.into_body(), 64 * 1024).await.unwrap();
        (status, serde_json::from_slice(&bytes).unwrap())
    }

    #[tokio::test]
    async fn an_internal_error_keeps_its_detail_in_the_log() {
        let (status, body) = body_of(AppError::internal_server_error("relation users: deadlock")).await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        let message = body["errors"]["body"][0].as_str().unwrap();
        assert!(message.starts_with(SAFE_INTERNAL_MESSAGE) && !message.contains("deadlock"), "{message}");
    }

    #[tokio::test]
    async fn a_refusal_is_one_message_in_the_challenge_envelope() {
        let (status, body) = body_of(AppError::UnprocessableEntity("title is required")).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body, serde_json::json!({ "errors": { "body": ["title is required"] } }));
    }
}
