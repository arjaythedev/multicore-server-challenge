//! SQL for comments. Each request is one statement: the article lookup rides along.

use tokio_postgres::types::Type;

use super::model::{AuthorOf, CommentRow, ThreadRow};
use crate::error::AppError;
use crate::services::db::{Db, Stmt};

static THREAD: Stmt = Stmt {
    sql: "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
            FROM articles a
            LEFT JOIN LATERAL (
                 SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
                  WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
            LEFT JOIN users u ON u.id = c.author_id
           WHERE a.slug = $2
           ORDER BY c.created_at DESC, c.id DESC",
    types: &[Type::INT8, Type::TEXT],
};
static INSERT: Stmt = Stmt {
    sql: "WITH target AS (SELECT id FROM articles WHERE slug = $1),
               c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM target
                     RETURNING id, body, created_at, updated_at, author_id)
          SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
            FROM c JOIN users u ON u.id = c.author_id",
    types: &[Type::TEXT, Type::INT8, Type::TEXT],
};
static DELETE_OWN: Stmt = Stmt {
    sql: "WITH target AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                           WHERE c.id = $1 AND a.slug = $2),
               removed AS (DELETE FROM comments WHERE id = (SELECT id FROM target WHERE author_id = $3))
          SELECT author_id FROM target",
    types: &[Type::INT8, Type::TEXT, Type::INT8],
};

pub(crate) static STATEMENTS: &[&Stmt] = &[&THREAD, &INSERT, &DELETE_OWN];

/// No row: no such article. One row of NULLs: the article has no comments.
pub async fn thread(db: &Db, viewer: i64, slug: &str) -> Result<Vec<ThreadRow>, AppError> {
    db.read().all(&THREAD, &[&viewer, &slug]).await.map_err(AppError::db("comment thread"))
}

/// None: no such article.
pub async fn insert(db: &Db, author: i64, slug: &str, body: &str) -> Result<Option<CommentRow>, AppError> {
    db.write().opt(&INSERT, &[&slug, &author, &body]).await.map_err(AppError::db("insert comment"))
}

/// Deletes the comment only when `author` wrote it; the row names who did. None: no such comment under that slug.
pub async fn delete_own(db: &Db, author: i64, slug: &str, id: i64) -> Result<Option<AuthorOf>, AppError> {
    db.write().opt(&DELETE_OWN, &[&id, &slug, &author]).await.map_err(AppError::db("delete comment"))
}
