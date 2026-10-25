//! Account rules: a fresh token on sign-up and login, the presented one everywhere else.

use super::data;
use super::model::{User, UserChanges};
use crate::error::AppError;
use crate::features::auth::{password, tokens, Claims};
use crate::AppState;

pub struct SignUp {
    pub username: String,
    pub email: String,
    pub password: String,
}

pub struct Settings {
    pub email: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub bio: Option<String>,
    pub image: Option<String>,
}

pub async fn register(ctx: &AppState, input: SignUp) -> Result<User, AppError> {
    let password_hash = password::hash(input.password).await?;
    let row = data::insert_user(&ctx.db, &input.username, &input.email, &password_hash).await?;
    let token = tokens::issue(row.id)?;
    Ok(User::new(row, token))
}

/// An unknown email and a wrong password are the same 401.
pub async fn login(ctx: &AppState, email: &str, plain: String) -> Result<User, AppError> {
    let row = data::login_row_by_email(&ctx.db, email).await?.ok_or(AppError::Unauthorized)?;
    if !password::verify(plain, row.password_hash).await? {
        return Err(AppError::Unauthorized);
    }
    let token = tokens::issue(row.user.id)?;
    Ok(User::new(row.user, token))
}

/// A valid token whose user is gone is a 401, never a 404.
pub async fn current(ctx: &AppState, claims: Claims) -> Result<User, AppError> {
    let row = data::user_by_id(&ctx.db, claims.uid).await?.ok_or(AppError::Unauthorized)?;
    Ok(User::new(row, claims.token))
}

pub async fn update(ctx: &AppState, claims: Claims, input: Settings) -> Result<User, AppError> {
    let password_hash = match input.password {
        Some(plain) => Some(password::hash(plain).await?),
        None => None,
    };
    let changes = UserChanges { email: input.email, username: input.username, password_hash, bio: input.bio, image: input.image };
    let row = data::update_user(&ctx.db, claims.uid, changes).await?.ok_or(AppError::Unauthorized)?;
    Ok(User::new(row, claims.token))
}
