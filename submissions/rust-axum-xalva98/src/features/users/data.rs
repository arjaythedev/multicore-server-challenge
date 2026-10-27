//! SQL for accounts. Named statements, no business rules (see `service.rs`).

use tokio_postgres::types::Type;

use super::model::{LoginRow, UserChanges, UserRow};
use crate::error::AppError;
use crate::services::db::{Db, Stmt};

const TAKEN: &str = "username or email is already taken";

static INSERT_USER: Stmt = Stmt {
    sql: "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
          RETURNING id, username, email, bio, image",
    types: &[Type::TEXT, Type::TEXT, Type::TEXT],
};
static LOGIN_ROW_BY_EMAIL: Stmt = Stmt {
    sql: "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
    types: &[Type::TEXT],
};
static USER_BY_ID: Stmt = Stmt { sql: "SELECT id, username, email, bio, image FROM users WHERE id = $1", types: &[Type::INT8] };
static UPDATE_USER: Stmt = Stmt {
    sql: "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                           password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio),
                           image = COALESCE($6, image)
           WHERE id = $1
          RETURNING id, username, email, bio, image",
    types: &[Type::INT8, Type::TEXT, Type::TEXT, Type::TEXT, Type::TEXT, Type::TEXT],
};

pub(crate) static STATEMENTS: &[&Stmt] = &[&INSERT_USER, &LOGIN_ROW_BY_EMAIL, &USER_BY_ID, &UPDATE_USER];

pub async fn insert_user(db: &Db, username: &str, email: &str, password_hash: &str) -> Result<UserRow, AppError> {
    db.write()
        .opt(&INSERT_USER, &[&username, &email, &password_hash])
        .await
        .map_err(AppError::unique_or_db(TAKEN, "insert user"))?
        .ok_or_else(|| AppError::internal_server_error("insert user returned no row"))
}

pub async fn login_row_by_email(db: &Db, email: &str) -> Result<Option<LoginRow>, AppError> {
    db.read().opt(&LOGIN_ROW_BY_EMAIL, &[&email]).await.map_err(AppError::db("user by email"))
}

pub async fn user_by_id(db: &Db, id: i64) -> Result<Option<UserRow>, AppError> {
    db.read().opt(&USER_BY_ID, &[&id]).await.map_err(AppError::db("user by id"))
}

pub async fn update_user(db: &Db, id: i64, c: UserChanges) -> Result<Option<UserRow>, AppError> {
    db.write()
        .opt(&UPDATE_USER, &[&id, &c.email, &c.username, &c.password_hash, &c.bio, &c.image])
        .await
        .map_err(AppError::unique_or_db(TAKEN, "update user"))
}
