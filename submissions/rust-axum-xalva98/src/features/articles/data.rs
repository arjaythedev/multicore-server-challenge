//! SQL for articles. Named statements, no business rules (see `service.rs`).

use tokio_postgres::types::Type;

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
static CREATE: Stmt =
    Stmt { sql: sql::CREATE, types: &[Type::INT8, Type::TEXT, Type::TEXT, Type::TEXT, Type::TEXT_ARRAY] };

pub(crate) static STATEMENTS: &[&Stmt] = &[
    &LIST_ALL, &LIST_TAG, &LIST_AUTHOR, &LIST_FAVORITED, &LIST_FEED, &COUNT_ALL, &COUNT_TAG, &COUNT_AUTHOR,
    &COUNT_FAVORITED, &COUNT_FEED, &BY_SLUG, &BY_ID, &CREATE, &UPDATE_OWN, &DELETE_OWN,
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

/// The article and its tags in one statement on the write connections; the row is the article as created.
pub async fn create(db: &Db, author: i64, new: &NewArticle) -> Result<ArticleRow, AppError> {
    db.write()
        .opt(&CREATE, &[&author, &new.title, &new.description, &new.body, &new.tags])
        .await
        .map_err(AppError::db("create article"))?
        .ok_or_else(|| AppError::internal_server_error("create article returned no row"))
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
