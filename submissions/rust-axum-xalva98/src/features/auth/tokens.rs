use jsonwebtoken::{encode, get_current_timestamp, Header};

use super::model::{IssuedClaims, KEYS};
use crate::error::AppError;

const TOKEN_TTL_SECS: u64 = 30 * 24 * 60 * 60;

pub fn issue(uid: i64) -> Result<String, AppError> {
    let now = get_current_timestamp();
    let claims = IssuedClaims { sub: uid.to_string(), iat: now, exp: now + TOKEN_TTL_SECS };
    encode(&Header::default(), &claims, &KEYS.encoding)
        .map_err(|e| AppError::internal_server_error(format!("token: {e}")))
}
