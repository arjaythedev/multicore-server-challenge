//! POST /api/users, POST /api/users/login, GET /api/user, PUT /api/user.

use serde::{Deserialize, Serialize};

use super::{AppError, Reply, Req};
use crate::http::NonEmpty;
use crate::model::{Credentials, User};
use crate::pwhash;
use crate::sql::{CREDENTIALS_BY_EMAIL, USER_BY_ID, USER_INSERT, USER_UPDATE};

#[derive(Deserialize)]
struct Body<T> {
    user: T,
}

#[derive(Serialize)]
struct UserResponse {
    user: User,
}

#[derive(Deserialize)]
struct Registration {
    username: NonEmpty,
    email: NonEmpty,
    password: NonEmpty,
}

#[derive(Deserialize)]
struct Login {
    email: NonEmpty,
    password: NonEmpty,
}

/// Fields that are absent or `null` stay as they are.
#[derive(Deserialize)]
struct Changes {
    email: Option<NonEmpty>,
    username: Option<NonEmpty>,
    password: Option<NonEmpty>,
    bio: Option<String>,
    image: Option<String>,
}

/// bcrypt only uses the first 72 bytes; longer passwords are 422 rather than silently truncated.
fn hash(password: &str) -> Result<String, AppError> {
    if password.len() > 72 {
        return Err(AppError::Unprocessable);
    }
    pwhash::hash(password).ok_or_else(|| AppError::Internal("bcrypt hash failed".into()))
}

fn user_response(user: Option<User>, token: String) -> Result<Reply, AppError> {
    let user = user.ok_or(AppError::Unauthorized)?;
    Reply::ok(&UserResponse { user: User { token, ..user } })
}

pub fn register(req: &Req) -> Result<Reply, AppError> {
    let Body { user: new }: Body<Registration> = req.body()?;
    let password_hash = hash(&new.password)?;
    let rows = req.db().query(&USER_INSERT, &[&new.username, &new.email, &password_hash])?;
    let user: User = rows.first()?.ok_or(AppError::Internal("insert returned no row".into()))?;
    let token = req.jwt().issue(user.id);
    Reply::created(&UserResponse { user: User { token, ..user } })
}

pub fn login(req: &Req) -> Result<Reply, AppError> {
    let Body { user: login }: Body<Login> = req.body()?;
    let rows = req.db().query(&CREDENTIALS_BY_EMAIL, &[&login.email])?;
    let credentials: Credentials = rows.first()?.ok_or(AppError::Unauthorized)?;
    if !pwhash::verify(&login.password, &credentials.password_hash) {
        return Err(AppError::Unauthorized);
    }
    let token = req.jwt().issue(credentials.user.id);
    user_response(Some(credentials.user), token)
}

pub fn current(req: &Req) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let rows = req.db().query(&USER_BY_ID, &[&auth.id])?;
    user_response(rows.first()?, auth.token)
}

pub fn update(req: &Req) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let Body { user: changes }: Body<Changes> = req.body()?;
    let password_hash = changes.password.as_deref().map(hash).transpose()?;
    let rows = req.db().query(
        &USER_UPDATE,
        &[&auth.id, &changes.email, &changes.username, &password_hash, &changes.bio, &changes.image],
    )?;
    user_response(rows.first()?, auth.token)
}
