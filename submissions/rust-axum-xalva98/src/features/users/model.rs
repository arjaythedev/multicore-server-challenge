use serde::Serialize;
use tokio_postgres::Row;

use crate::services::db::{FromRow, PgError};

pub struct UserRow {
    pub id: i64,
    pub username: String,
    pub email: String,
    pub bio: Option<String>,
    pub image: Option<String>,
}

impl FromRow for UserRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(UserRow {
            id: row.try_get("id")?,
            username: row.try_get("username")?,
            email: row.try_get("email")?,
            bio: row.try_get("bio")?,
            image: row.try_get("image")?,
        })
    }
}

pub struct LoginRow {
    pub user: UserRow,
    pub password_hash: String,
}

impl FromRow for LoginRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(LoginRow { user: UserRow::from_row(row)?, password_hash: row.try_get("password_hash")? })
    }
}

/// What the settings form may change; `None` keeps the stored value.
pub struct UserChanges {
    pub email: Option<String>,
    pub username: Option<String>,
    pub password_hash: Option<String>,
    pub bio: Option<String>,
    pub image: Option<String>,
}

#[derive(Serialize)]
pub struct User {
    pub email: String,
    pub token: String,
    pub username: String,
    pub bio: Option<String>,
    pub image: Option<String>,
}

impl User {
    pub fn new(row: UserRow, token: String) -> Self {
        User { email: row.email, token, username: row.username, bio: row.bio, image: row.image }
    }
}

#[derive(Serialize)]
pub struct UserEnvelope {
    pub user: User,
}
