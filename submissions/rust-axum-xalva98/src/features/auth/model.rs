use std::sync::LazyLock;

use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Validation};
use serde::{Deserialize, Serialize};

pub struct Keys {
    pub encoding: EncodingKey,
    pub decoding: DecodingKey,
    pub validation: Validation,
}

impl Keys {
    fn new(secret: &[u8]) -> Self {
        let mut validation = Validation::new(Algorithm::HS256);
        validation.leeway = 0;
        validation.validate_nbf = true;
        validation.validate_aud = false;
        Self { encoding: EncodingKey::from_secret(secret), decoding: DecodingKey::from_secret(secret), validation }
    }
}

/// `assert_bootable` refuses to start without JWT_SECRET, so the empty fallback never signs anything.
pub static KEYS: LazyLock<Keys> = LazyLock::new(|| Keys::new(std::env::var("JWT_SECRET").unwrap_or_default().as_bytes()));

pub fn assert_bootable() -> anyhow::Result<()> {
    if std::env::var("JWT_SECRET").map_or(true, |s| s.is_empty()) {
        anyhow::bail!("JWT_SECRET must be set");
    }
    LazyLock::force(&KEYS);
    Ok(())
}

/// A verified token: the user id from `sub` and the token as presented.
#[derive(Clone, Debug)]
pub struct Claims {
    pub uid: i64,
    pub token: String,
}

#[derive(Serialize)]
pub(super) struct IssuedClaims {
    pub sub: String,
    pub iat: u64,
    pub exp: u64,
}

#[derive(Deserialize)]
pub(super) struct TokenClaims {
    #[serde(default)]
    pub sub: String,
}

/// The id an auth-optional query is asked for: 0 is nobody, no user has it.
pub fn viewer(claims: Option<&Claims>) -> i64 {
    claims.map_or(0, |c| c.uid)
}
