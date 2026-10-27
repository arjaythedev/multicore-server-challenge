//! SQL for profiles. A follow change and the profile it answers with are one statement.

use tokio_postgres::types::Type;

use super::model::{AuthorRow, ProfileRow};
use crate::error::AppError;
use crate::services::db::{Db, Stmt};

static PROFILE: Stmt = Stmt {
    sql: "SELECT u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
            FROM users u WHERE u.username = $2",
    types: &[Type::INT8, Type::TEXT],
};
static FOLLOW: Stmt = Stmt {
    sql: "WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2),
               changed AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM target ON CONFLICT DO NOTHING)
          SELECT username, bio, image FROM target",
    types: &[Type::INT8, Type::TEXT],
};
static UNFOLLOW: Stmt = Stmt {
    sql: "WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2),
               changed AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM target))
          SELECT username, bio, image FROM target",
    types: &[Type::INT8, Type::TEXT],
};

pub(crate) static STATEMENTS: &[&Stmt] = &[&PROFILE, &FOLLOW, &UNFOLLOW];

pub async fn profile(db: &Db, viewer: i64, username: &str) -> Result<Option<ProfileRow>, AppError> {
    db.read().opt(&PROFILE, &[&viewer, &username]).await.map_err(AppError::db("profile"))
}

/// None: no such user. A second follow changes nothing.
pub async fn follow(db: &Db, follower: i64, username: &str) -> Result<Option<AuthorRow>, AppError> {
    db.write().opt(&FOLLOW, &[&follower, &username]).await.map_err(AppError::db("follow"))
}

pub async fn unfollow(db: &Db, follower: i64, username: &str) -> Result<Option<AuthorRow>, AppError> {
    db.write().opt(&UNFOLLOW, &[&follower, &username]).await.map_err(AppError::db("unfollow"))
}
