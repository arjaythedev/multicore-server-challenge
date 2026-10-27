//! Article rules: one filter per list, the author alone edits or deletes.

use super::data;
use super::model::{Article, ArticleChanges, ArticleList, ListFilter, NewArticle};
use crate::error::AppError;
use crate::services::paging::{ListQuery, Page};
use crate::AppState;

pub fn filter_of(query: ListQuery) -> ListFilter {
    if let Some(tag) = query.tag {
        ListFilter::Tag(tag)
    } else if let Some(author) = query.author {
        ListFilter::Author(author)
    } else if let Some(username) = query.favorited {
        ListFilter::Favorited(username)
    } else {
        ListFilter::All
    }
}

fn listed((rows, articles_count): (Vec<super::ArticleRow>, i64)) -> ArticleList {
    ArticleList { articles: rows.into_iter().map(Article::from).collect(), articles_count }
}

pub async fn list(ctx: &AppState, viewer: i64, filter: ListFilter, page: Page) -> Result<ArticleList, AppError> {
    data::list(&ctx.db, viewer, &filter, page).await.map(listed)
}

pub async fn feed(ctx: &AppState, viewer: i64, page: Page) -> Result<ArticleList, AppError> {
    data::feed(&ctx.db, viewer, page).await.map(listed)
}

pub async fn by_slug(ctx: &AppState, viewer: i64, slug: &str) -> Result<Article, AppError> {
    data::by_slug(&ctx.db, viewer, slug).await?.map(Article::from).ok_or(AppError::NotFound)
}

pub async fn create(ctx: &AppState, author: i64, new: NewArticle) -> Result<Article, AppError> {
    let id = data::create(&ctx.db, author, &new).await?;
    let row = data::by_id(&ctx.db, author, id).await?;
    row.map(Article::from).ok_or_else(|| AppError::internal_server_error(format!("article {id} gone right after its commit")))
}

pub async fn update(ctx: &AppState, author: i64, slug: &str, changes: ArticleChanges) -> Result<Article, AppError> {
    let owner = data::update_own(&ctx.db, author, slug, changes).await?.ok_or(AppError::NotFound)?;
    if owner.author_id != author {
        return Err(AppError::Forbidden);
    }
    data::by_id(&ctx.db, author, owner.id).await?.map(Article::from).ok_or(AppError::NotFound)
}

pub async fn delete(ctx: &AppState, author: i64, slug: &str) -> Result<(), AppError> {
    let owner = data::delete_own(&ctx.db, author, slug).await?.ok_or(AppError::NotFound)?;
    if owner.author_id != author {
        return Err(AppError::Forbidden);
    }
    Ok(())
}
