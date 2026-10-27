//! SQL for articles. Named statements, no business rules (see `service.rs`).

use tokio_postgres::types::Type;
use tokio_postgres::Client;

use super::model::{ArticleChanges, ArticleRow, ListFilter, ListedRow, NewArticle, OwnerRow};
use super::sql;
use crate::error::AppError;
use crate::services::db::{Db, Params, PgError, Stmt};
use crate::services::paging::Page;

const PAGE: &[Type] = &[Type::INT8, Type::INT8, Type::INT8];
const FILTERED_PAGE: &[Type] = &[Type::INT8, Type::INT8, Type::INT8, Type::TEXT];

static LIST_ALL: Stmt = Stmt { sql: sql::LIST_ALL, types: PAGE };
static LIST_TAG: Stmt = Stmt { sql: sql::LIST_TAG, types: FILTERED_PAGE };
static LIST_AUTHOR: Stmt = Stmt { sql: sql::LIST_AUTHOR, types: FILTERED_PAGE };
static LIST_FAVORITED: Stmt = Stmt { sql: sql::LIST_FAVORITED, types: FILTERED_PAGE };
static LIST_FEED: Stmt = Stmt { sql: sql::LIST_FEED, types: PAGE };
static COUNT_ALL: Stmt = Stmt { sql: sql::COUNT_ALL, types: &[] };
static COUNT_TAG: Stmt = Stmt { sql: sql::COUNT_TAG, types: &[Type::TEXT] };
static COUNT_AUTHOR: Stmt = Stmt { sql: sql::COUNT_AUTHOR, types: &[Type::TEXT] };
static COUNT_FAVORITED: Stmt = Stmt { sql: sql::COUNT_FAVORITED, types: &[Type::TEXT] };
static COUNT_FEED: Stmt = Stmt { sql: sql::COUNT_FEED, types: &[Type::INT8] };
static BY_SLUG: Stmt = Stmt { sql: sql::BY_SLUG, types: &[Type::INT8, Type::TEXT] };
static BY_ID: Stmt = Stmt { sql: sql::BY_ID, types: &[Type::INT8, Type::INT8] };
static UPDATE_OWN: Stmt = Stmt { sql: sql::UPDATE, types: &[Type::TEXT, Type::INT8, Type::TEXT, Type::TEXT, Type::TEXT] };
static DELETE_OWN: Stmt = Stmt { sql: sql::DELETE, types: &[Type::TEXT, Type::INT8] };
static INSERT: Stmt = Stmt { sql: sql::INSERT, types: &[Type::INT8, Type::TEXT, Type::TEXT, Type::TEXT] };
static INSERT_TAGS: Stmt = Stmt { sql: sql::INSERT_TAGS, types: &[Type::TEXT_ARRAY] };
static LINK_TAGS: Stmt = Stmt { sql: sql::LINK_TAGS, types: &[Type::INT8, Type::TEXT_ARRAY] };

pub(crate) static STATEMENTS: &[&Stmt] = &[
    &LIST_ALL, &LIST_TAG, &LIST_AUTHOR, &LIST_FAVORITED, &LIST_FEED, &COUNT_ALL, &COUNT_TAG, &COUNT_AUTHOR,
    &COUNT_FAVORITED, &COUNT_FEED, &BY_SLUG, &BY_ID, &UPDATE_OWN, &DELETE_OWN,
];

/// The count rides in the page statement; only an empty page needs a second statement for it.
async fn page_with_count(
    db: &Db,
    page_stmt: &'static Stmt,
    page_params: Params<'_>,
    count_stmt: &'static Stmt,
    count_params: Params<'_>,
) -> Result<(Vec<ArticleRow>, i64), PgError> {
    let rows = db.read().all::<ListedRow>(page_stmt, page_params).await?;
    if let Some(first) = rows.first() {
        let count = first.articles_count;
        return Ok((rows.into_iter().map(|r| r.article).collect(), count));
    }
    Ok((Vec::new(), db.read().scalar::<i64>(count_stmt, count_params).await?.unwrap_or(0)))
}

pub async fn list(db: &Db, viewer: i64, filter: &ListFilter, page: Page) -> Result<(Vec<ArticleRow>, i64), AppError> {
    let (limit, offset) = (page.limit, page.offset);
    let r = match filter {
        ListFilter::All => page_with_count(db, &LIST_ALL, &[&viewer, &limit, &offset], &COUNT_ALL, &[]).await,
        ListFilter::Tag(tag) => {
            page_with_count(db, &LIST_TAG, &[&viewer, &limit, &offset, tag], &COUNT_TAG, &[tag]).await
        }
        ListFilter::Author(username) => {
            page_with_count(db, &LIST_AUTHOR, &[&viewer, &limit, &offset, username], &COUNT_AUTHOR, &[username]).await
        }
        ListFilter::Favorited(username) => {
            page_with_count(db, &LIST_FAVORITED, &[&viewer, &limit, &offset, username], &COUNT_FAVORITED, &[username])
                .await
        }
    };
    r.map_err(AppError::db("article list"))
}

pub async fn feed(db: &Db, viewer: i64, page: Page) -> Result<(Vec<ArticleRow>, i64), AppError> {
    page_with_count(db, &LIST_FEED, &[&viewer, &page.limit, &page.offset], &COUNT_FEED, &[&viewer])
        .await
        .map_err(AppError::db("feed"))
}

pub async fn by_slug(db: &Db, viewer: i64, slug: &str) -> Result<Option<ArticleRow>, AppError> {
    db.read().opt(&BY_SLUG, &[&viewer, &slug]).await.map_err(AppError::db("article by slug"))
}

pub async fn by_id(db: &Db, viewer: i64, id: i64) -> Result<Option<ArticleRow>, AppError> {
    db.read().opt(&BY_ID, &[&viewer, &id]).await.map_err(AppError::db("article by id"))
}

/// The article, its new tags and its tag links in one transaction; a tag another writer just created is linked too.
pub async fn create(db: &Db, author: i64, new: &NewArticle) -> Result<i64, AppError> {
    let mut c = db.transaction_connection().await?;
    let r = insert_article(&mut c, author, new).await;
    c.release(r).map_err(AppError::db("create article"))
}

async fn insert_article(client: &mut Client, author: i64, new: &NewArticle) -> Result<i64, PgError> {
    let tx = client.transaction().await?;
    let insert = tx.prepare_typed(INSERT.sql, INSERT.types).await?;
    let id: i64 = tx.query_one(&insert, &[&author, &new.title, &new.description, &new.body]).await?.try_get(0)?;
    if !new.tags.is_empty() {
        let insert_tags = tx.prepare_typed(INSERT_TAGS.sql, INSERT_TAGS.types).await?;
        tx.execute(&insert_tags, &[&new.tags]).await?;
        let link_tags = tx.prepare_typed(LINK_TAGS.sql, LINK_TAGS.types).await?;
        tx.execute(&link_tags, &[&id, &new.tags]).await?;
    }
    tx.commit().await?;
    Ok(id)
}

/// Changes the article only when `author` wrote it; the row says who did.
pub async fn update_own(db: &Db, author: i64, slug: &str, c: ArticleChanges) -> Result<Option<OwnerRow>, AppError> {
    db.write()
        .opt(&UPDATE_OWN, &[&slug, &author, &c.title, &c.description, &c.body])
        .await
        .map_err(AppError::db("update article"))
}

pub async fn delete_own(db: &Db, author: i64, slug: &str) -> Result<Option<OwnerRow>, AppError> {
    db.write().opt(&DELETE_OWN, &[&slug, &author]).await.map_err(AppError::db("delete article"))
}
