use axum::extract::{FromRequestParts, OptionalFromRequestParts};
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use jsonwebtoken::decode;

use super::model::{Claims, TokenClaims, KEYS};
use crate::error::AppError;
use crate::services::paging::digits;

/// No header (or an empty one) is anonymous; a header that is present but does not verify is a 401.
fn verify(parts: &Parts) -> Result<Option<Claims>, AppError> {
    let Some(value) = parts.headers.get(AUTHORIZATION).filter(|v| !v.is_empty()) else {
        return Ok(None);
    };
    let token = value.to_str().ok().and_then(|v| v.strip_prefix("Token ")).ok_or(AppError::Unauthorized)?;
    let claims = decode::<TokenClaims>(token, &KEYS.decoding, &KEYS.validation)
        .map_err(|_| AppError::Unauthorized)?
        .claims;
    let uid = digits(&claims.sub).filter(|id| *id > 0).ok_or(AppError::Unauthorized)?;
    Ok(Some(Claims { uid, token: token.to_string() }))
}

impl<S: Send + Sync> FromRequestParts<S> for Claims {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        verify(parts)?.ok_or(AppError::Unauthorized)
    }
}

impl<S: Send + Sync> OptionalFromRequestParts<S> for Claims {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Option<Self>, Self::Rejection> {
        verify(parts)
    }
}
