//! A JSON request body: whatever does not parse into the handler's type is a 422, whatever the Content-Type.

use axum::body::Bytes;
use axum::extract::{FromRequest, Request};
use serde::de::DeserializeOwned;

use crate::error::AppError;

pub struct JsonBody<T>(pub T);

impl<S, T> FromRequest<S> for JsonBody<T>
where
    S: Send + Sync,
    T: DeserializeOwned,
{
    type Rejection = AppError;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let bytes = Bytes::from_request(req, state)
            .await
            .map_err(|_| AppError::UnprocessableEntity("could not read the request body"))?;
        serde_json::from_slice(&bytes)
            .map(JsonBody)
            .map_err(|_| AppError::UnprocessableEntity("the request body is not the expected JSON object"))
    }
}

/// A field that must be sent and must not be empty.
pub fn required(value: Option<String>, missing: &'static str) -> Result<String, AppError> {
    value.filter(|v| !v.is_empty()).ok_or(AppError::UnprocessableEntity(missing))
}

/// Absent or null leaves the stored value; an empty string is refused.
pub fn non_empty_if_sent(value: Option<String>, empty: &'static str) -> Result<Option<String>, AppError> {
    match value {
        Some(v) if v.is_empty() => Err(AppError::UnprocessableEntity(empty)),
        other => Ok(other),
    }
}
