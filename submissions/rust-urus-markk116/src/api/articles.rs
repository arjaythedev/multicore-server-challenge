//! Article lists, the feed, single-article CRUD, favorites, and tags.

use serde::{Deserialize, Serialize};

use super::{AppError, Reply, Req};
use crate::db::{Rows, Stmt};
use crate::http::NonEmpty;
use crate::model::Article;
use crate::sql::*;

#[derive(Deserialize)]
struct Body<T> {
    article: T,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewArticle {
    title: NonEmpty,
    description: NonEmpty,
    body: NonEmpty,
    tag_list: Option<Vec<NonEmpty>>,
}

/// Fields that are absent or `null` stay as they are.
#[derive(Deserialize)]
struct Changes {
    title: Option<NonEmpty>,
    description: Option<NonEmpty>,
    body: Option<NonEmpty>,
}

#[derive(Serialize)]
struct ArticleResponse {
    article: Article,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ArticlesResponse {
    articles: Vec<Article>,
    articles_count: i64,
}

#[derive(Serialize)]
struct TagsResponse {
    tags: Vec<String>,
}

fn article_response(status: u16, rows: &Rows) -> Result<Reply, AppError> {
    let article = rows.first()?.ok_or(AppError::NotFound)?;
    Reply::json(status, &ArticleResponse { article })
}

fn articles_response(page: &Rows, count: &Rows) -> Result<Reply, AppError> {
    Reply::ok(&ArticlesResponse { articles: page.all()?, articles_count: count.first()?.unwrap_or(0) })
}

// ---------------------------------------------------------------------------
// lists
// ---------------------------------------------------------------------------

/// GET /api/articles: at most one filter applies, in the order tag, author, favorited.
pub fn list(req: &Req) -> Result<Reply, AppError> {
    let viewer = req.viewer()?;
    let query = req.query();
    let (limit, offset) = query.page()?;
    let filters: [(&str, &'static Stmt, &'static Stmt); 3] = [
        ("tag", &LIST_BY_TAG, &COUNT_BY_TAG),
        ("author", &LIST_BY_AUTHOR, &COUNT_BY_AUTHOR),
        ("favorited", &LIST_FAVORITED_BY, &COUNT_FAVORITED_BY),
    ];
    let filter = filters.into_iter().find_map(|(key, list, count)| Some((list, count, query.filter(key)?)));
    let [page, count] = match filter {
        Some((list, count, value)) => {
            req.db().batch([(list, &[&viewer, &limit, &offset, &value]), (count, &[&value])])?
        }
        None => req.db().batch([(&LIST_ALL, &[&viewer, &limit, &offset]), (&COUNT_ALL, &[])])?,
    };
    articles_response(&page, &count)
}

pub fn feed(req: &Req) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let (limit, offset) = req.query().page()?;
    let [page, count] =
        req.db().batch([(&LIST_FEED, &[&auth.id, &limit, &offset]), (&COUNT_FEED, &[&auth.id])])?;
    articles_response(&page, &count)
}

// ---------------------------------------------------------------------------
// single articles
// ---------------------------------------------------------------------------

pub fn get(req: &Req) -> Result<Reply, AppError> {
    let viewer = req.viewer()?;
    let slug = req.param("slug");
    article_response(200, &req.db().query(&ARTICLE_BY_SLUG, &[&viewer, &slug])?)
}

/// The insert, its tags and the read-back as one batch: one round trip, one transaction.
pub fn create(req: &Req) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let Body { article: new }: Body<NewArticle> = req.body()?;
    let tags: Vec<String> = new.tag_list.unwrap_or_default().into_iter().map(String::from).collect();
    let [_, _, _, article] = req.db().batch([
        (&ARTICLE_INSERT, &[&auth.id, &new.title, &new.description, &new.body]),
        (&TAGS_INSERT, &[&tags]),
        (&NEW_ARTICLE_TAGS, &[&tags]),
        (&NEW_ARTICLE, &[&auth.id]),
    ])?;
    article_response(201, &article)
}

/// The article's id, if the caller wrote it: 404 for an unknown slug, 403 if it isn't theirs.
fn owned_article(req: &Req, slug: &str, user_id: i64) -> Result<i64, AppError> {
    let (id, author_id): (i64, i64) =
        req.db().query(&ARTICLE_OWNER, &[&slug])?.first()?.ok_or(AppError::NotFound)?;
    if author_id != user_id {
        return Err(AppError::Forbidden);
    }
    Ok(id)
}

pub fn update(req: &Req) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let Body { article: changes }: Body<Changes> = req.body()?;
    let slug = req.param("slug");
    // Two round trips: the update goes by id, because a new title changes the slug.
    let id = owned_article(req, &slug, auth.id)?;
    let [_, article] = req.db().batch([
        (&ARTICLE_UPDATE, &[&id, &changes.title, &changes.description, &changes.body]),
        (&ARTICLE_BY_ID, &[&auth.id, &id]),
    ])?;
    article_response(200, &article)
}

pub fn delete(req: &Req) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let slug = req.param("slug");
    owned_article(req, &slug, auth.id)?;
    req.db().query(&ARTICLE_DELETE, &[&slug, &auth.id])?;
    Reply::no_content()
}

pub fn favorite(req: &Req) -> Result<Reply, AppError> {
    change_favorite(req, &FAVORITE)
}

pub fn unfavorite(req: &Req) -> Result<Reply, AppError> {
    change_favorite(req, &UNFAVORITE)
}

/// The change and the updated article in one batch; an unknown slug changes nothing (404).
fn change_favorite(req: &Req, change: &'static Stmt) -> Result<Reply, AppError> {
    let auth = req.auth()?;
    let slug = req.param("slug");
    let [_, article] = req.db().batch([(change, &[&auth.id, &slug]), (&ARTICLE_BY_SLUG, &[&auth.id, &slug])])?;
    article_response(200, &article)
}

pub fn tags(req: &Req) -> Result<Reply, AppError> {
    let tags = req.db().query(&TAGS, &[])?.all()?;
    Reply::ok(&TagsResponse { tags })
}
