use serde::Serialize;
use time::OffsetDateTime;
use tokio_postgres::Row;

use crate::features::profiles::Profile;
use crate::services::db::{FromRow, PgError};
use crate::services::timestamp;

/// One row per comment, or a single row of NULLs when the article exists without any.
pub struct ThreadRow {
    pub id: Option<i64>,
    pub body: Option<String>,
    pub created_at: Option<OffsetDateTime>,
    pub updated_at: Option<OffsetDateTime>,
    pub username: Option<String>,
    pub bio: Option<String>,
    pub image: Option<String>,
    pub following: bool,
}

impl FromRow for ThreadRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(ThreadRow {
            id: row.try_get("id")?,
            body: row.try_get("body")?,
            created_at: row.try_get("created_at")?,
            updated_at: row.try_get("updated_at")?,
            username: row.try_get("username")?,
            bio: row.try_get("bio")?,
            image: row.try_get("image")?,
            following: row.try_get("following")?,
        })
    }
}

pub struct CommentRow {
    pub id: i64,
    pub body: String,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
    pub username: String,
    pub bio: Option<String>,
    pub image: Option<String>,
}

impl FromRow for CommentRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(CommentRow {
            id: row.try_get("id")?,
            body: row.try_get("body")?,
            created_at: row.try_get("created_at")?,
            updated_at: row.try_get("updated_at")?,
            username: row.try_get("username")?,
            bio: row.try_get("bio")?,
            image: row.try_get("image")?,
        })
    }
}

pub struct AuthorOf {
    pub author_id: i64,
}

impl FromRow for AuthorOf {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(AuthorOf { author_id: row.try_get("author_id")? })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Comment {
    pub id: i64,
    #[serde(serialize_with = "timestamp::serialize")]
    pub created_at: OffsetDateTime,
    #[serde(serialize_with = "timestamp::serialize")]
    pub updated_at: OffsetDateTime,
    pub body: String,
    pub author: Profile,
}

impl ThreadRow {
    pub fn into_comment(self) -> Option<Comment> {
        Some(Comment {
            id: self.id?,
            created_at: self.created_at?,
            updated_at: self.updated_at?,
            body: self.body?,
            author: Profile { username: self.username?, bio: self.bio, image: self.image, following: self.following },
        })
    }
}

impl From<CommentRow> for Comment {
    fn from(r: CommentRow) -> Self {
        Comment {
            id: r.id,
            created_at: r.created_at,
            updated_at: r.updated_at,
            body: r.body,
            author: Profile { username: r.username, bio: r.bio, image: r.image, following: false },
        }
    }
}

#[derive(Serialize)]
pub struct CommentEnvelope {
    pub comment: Comment,
}

#[derive(Serialize)]
pub struct CommentList {
    pub comments: Vec<Comment>,
}
