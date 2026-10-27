use serde::Serialize;
use time::OffsetDateTime;
use tokio_postgres::Row;

use crate::features::profiles::Profile;
use crate::services::db::{FromRow, PgError};
use crate::services::timestamp;

/// One article as the statements in `sql.rs` return it; lists return `body` as NULL.
pub struct ArticleRow {
    pub slug: String,
    pub title: String,
    pub description: String,
    pub body: Option<String>,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
    pub tag_list: Vec<String>,
    pub favorites_count: i64,
    pub favorited: bool,
    pub username: String,
    pub bio: Option<String>,
    pub image: Option<String>,
    pub following: bool,
}

impl FromRow for ArticleRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(ArticleRow {
            slug: row.try_get("slug")?,
            title: row.try_get("title")?,
            description: row.try_get("description")?,
            body: row.try_get("body")?,
            created_at: row.try_get("created_at")?,
            updated_at: row.try_get("updated_at")?,
            tag_list: row.try_get("tag_list")?,
            favorites_count: row.try_get("favorites_count")?,
            favorited: row.try_get("favorited")?,
            username: row.try_get("username")?,
            bio: row.try_get("bio")?,
            image: row.try_get("image")?,
            following: row.try_get("following")?,
        })
    }
}

pub struct ListedRow {
    pub article: ArticleRow,
    pub articles_count: i64,
}

impl FromRow for ListedRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(ListedRow { article: ArticleRow::from_row(row)?, articles_count: row.try_get("articles_count")? })
    }
}

pub struct OwnerRow {
    pub id: i64,
    pub author_id: i64,
}

impl FromRow for OwnerRow {
    fn from_row(row: &Row) -> Result<Self, PgError> {
        Ok(OwnerRow { id: row.try_get("id")?, author_id: row.try_get("author_id")? })
    }
}

/// Which list: at most one filter applies, the first of tag, author, favorited.
pub enum ListFilter {
    All,
    Tag(String),
    Author(String),
    Favorited(String),
}

pub struct NewArticle {
    pub title: String,
    pub description: String,
    pub body: String,
    pub tags: Vec<String>,
}

pub struct ArticleChanges {
    pub title: Option<String>,
    pub description: Option<String>,
    pub body: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Article {
    pub slug: String,
    pub title: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    pub tag_list: Vec<String>,
    #[serde(serialize_with = "timestamp::serialize")]
    pub created_at: OffsetDateTime,
    #[serde(serialize_with = "timestamp::serialize")]
    pub updated_at: OffsetDateTime,
    pub favorited: bool,
    pub favorites_count: i64,
    pub author: Profile,
}

impl From<ArticleRow> for Article {
    fn from(r: ArticleRow) -> Self {
        Article {
            slug: r.slug,
            title: r.title,
            description: r.description,
            body: r.body,
            tag_list: r.tag_list,
            created_at: r.created_at,
            updated_at: r.updated_at,
            favorited: r.favorited,
            favorites_count: r.favorites_count,
            author: Profile { username: r.username, bio: r.bio, image: r.image, following: r.following },
        }
    }
}

#[derive(Serialize)]
pub struct ArticleEnvelope {
    pub article: Article,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArticleList {
    pub articles: Vec<Article>,
    pub articles_count: i64,
}
